class Account::Import::Admission < ApplicationRecord
  MAX_ATTEMPTS = 3
  MAX_IDENTITY_BYTES = 1.gigabyte
  DEFAULT_ACCOUNT_BYTES = 1.gigabyte
  STALE_AFTER = 1.hour

  class NotRecoverable < StandardError; end

  class Rejected < StandardError
    attr_reader :status

    def initialize(status)
      @status = status
      super("Import rejected")
    end
  end

  belongs_to :identity
  belongs_to :account, optional: true
  belongs_to :import, class_name: "Account::Import", optional: true

  scope :unfinished, -> { where(finished_at: nil) }

  def self.claim(identity:, import: nil)
    transaction do
      # The global identity locks first, including on SQLite, before any reads.
      Identity.where(id: identity.id).update_all("updated_at = updated_at")
      if !import && Account::Import.where(identity: identity, status: %w[ pending processing ]).exists?
        raise Account::Import::AlreadyInProgressError, "An import is already in progress"
      end
      attempts = where(identity: identity)
      if attempts.unfinished.exists? || attempts.where(created_at: 24.hours.ago..).count >= MAX_ATTEMPTS
        raise Rejected.new(:too_many_requests)
      end
      create!(identity: identity, import: import)
    end
  end

  def self.account_limit(account)
    limit = account.respond_to?(:storage_limit) ? account.storage_limit : DEFAULT_ACCOUNT_BYTES
    unless limit.is_a?(Integer) && limit.positive?
      raise Account::Import::InsufficientStorageSpaceError, "account capacity is unknown"
    end
    limit
  end

  def reserve(account:, bytes:)
    self.class.transaction do
      Identity.where(id: identity_id).update_all("updated_at = updated_at")
      Storage::UploadReservation.serialize_account(account) do
        reload
        raise Rejected.new(:too_many_requests) if finished_at
        unless account_id == account.id && reserved_bytes == bytes
          required = account.bytes_used_exact - reserved_bytes + bytes
          identity_bytes = self.class.unfinished.where(identity_id: identity_id).where.not(id: id).sum(:reserved_bytes)
          if required > self.class.account_limit(account) || identity_bytes + bytes > MAX_IDENTITY_BYTES
            raise Account::Import::InsufficientStorageSpaceError, "import exceeds available quota"
          end
          update!(account: account, reserved_bytes: bytes)
        end
      end
    end
  end

  def finish
    update!(reserved_bytes: 0, finished_at: Time.current)
  end

  # Operator path for a slot that a stopped request or a destroyed account left
  # unfinished. Age alone is never enough: a failed import deletes its objects
  # before it releases the charge, and anything still active or stored refuses.
  def recover
    if import&.failed?
      import.purge_failed_files
    else
      self.class.transaction do
        Identity.where(id: identity_id).update_all("updated_at = updated_at")
        reload
        unless finished_at
          ensure_recoverable
          finish
        end
      end
    end
    self
  end

  private
    def ensure_recoverable
      if created_at > STALE_AFTER.ago
        raise NotRecoverable, "admission #{id} is less than #{STALE_AFTER.inspect} old; its request may still run"
      elsif import
        raise NotRecoverable, "import #{import.id} is #{import.status}"
      elsif account_id && Account::Import.where(account_id: account_id, status: %w[ pending processing ]).exists?
        raise NotRecoverable, "account #{account_id} has an active import"
      elsif account_id && ActiveStorage::Blob.where(account_id: account_id).exists?
        raise NotRecoverable, "account #{account_id} still has storage objects"
      end
    end
end
