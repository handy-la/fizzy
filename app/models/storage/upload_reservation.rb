class Storage::UploadReservation < ApplicationRecord
  MAX_OBJECT_BYTES = 100.megabytes
  DEFAULT_ACCOUNT_BYTES = 10.gigabytes
  MAX_IDENTITY_UPLOADS = 20
  MAX_ACCOUNT_UPLOADS = 100
  PURGE_GRACE = 1.hour
  LEGACY_EXPIRY = 48.hours
  DRAFT_RETENTION = 30.days

  class Rejected < StandardError
    attr_reader :status

    def initialize(status)
      @status = status
      super("Direct upload rejected")
    end
  end

  belongs_to :account
  belongs_to :identity, optional: true
  belongs_to :blob, class_name: "ActiveStorage::Blob"

  scope :in_flight, -> { where(created_at: (ActiveStorage.service_urls_for_direct_uploads_expire_in + PURGE_GRACE).ago..) }

  def self.reserve(account:, identity:, attributes:)
    size = Integer(attributes[:byte_size].to_s, 10) rescue nil
    raise Rejected.new(:unprocessable_entity) unless size && size.positive?
    raise Rejected.new(:content_too_large) if size > MAX_OBJECT_BYTES

    transaction do
      # UPDATE acquires a write lock on SQLite and a row lock on MySQL.
      # Lock the global identity before the account, before any quota reads.
      Identity.where(id: identity.id).update_all("updated_at = updated_at")
      serialize_account(account) do
        raise Rejected.new(:too_many_requests) if in_flight.where(identity: identity).count >= MAX_IDENTITY_UPLOADS
        raise Rejected.new(:too_many_requests) if in_flight.where(account: account).count >= MAX_ACCOUNT_UPLOADS
        limit = account.respond_to?(:storage_limit) ? account.storage_limit : DEFAULT_ACCOUNT_BYTES
        raise Rejected.new(:unprocessable_entity) if account.bytes_used_exact + size > limit

        expires_at = ActiveStorage.service_urls_for_direct_uploads_expire_in.from_now
        metadata = (attributes[:metadata] || {}).merge("quota_upload" => true,
          "quota_identity_id" => identity.id, "quota_expires_at" => expires_at.iso8601(6))
        blob = ActiveStorage::Blob.create_before_direct_upload!(**attributes.merge(byte_size: size, metadata: metadata))
        create!(account: account, identity: identity, blob: blob, byte_size: size,
          expires_at: DRAFT_RETENTION.from_now)
        yield blob
      end
    end
  end

  def self.serialize_account(account)
    transaction do
      Account.where(id: account&.id).update_all("updated_at = updated_at")
      yield
    end
  end

  def self.cleanup
    where(expires_at: ..PURGE_GRACE.ago).find_each(&:purge)

    # A successful upload can live in a local-save draft before it is attached.
    # Empty uploads need no draft retention once their URL and grace expire.
    where(created_at: ..(ActiveStorage.service_urls_for_direct_uploads_expire_in + PURGE_GRACE).ago)
      .where(expires_at: PURGE_GRACE.ago..).find_each do |reservation|
        blob = reservation.blob
        url_expires_at = Time.iso8601(blob.metadata["quota_expires_at"])
        if url_expires_at + PURGE_GRACE <= Time.current && !blob.service.exist?(blob.key)
          reservation.purge
        end
      end

    # Also remove abandoned blobs issued before reservations were introduced.
    # Their old signed upload URLs could remain usable for 48 hours.
    ActiveStorage::Blob.unattached.where(created_at: ..([ LEGACY_EXPIRY, DRAFT_RETENTION ].max + PURGE_GRACE).ago).find_each do |blob|
      serialize_account(blob.account) do
        if !blob.attachments.exists? && !exists?(blob: blob)
          blob.delete
          blob.destroy!
        end
      end
    end
  end

  def purge
    self.class.serialize_account(account) do
      if self.class.exists?(id: id) && !blob.attachments.exists?
        # Delete the object first. A service failure retains both the blob and
        # the charge, so the next sweep can retry without losing the key.
        blob.delete
        blob.destroy!
        destroy!
      end
    end
  end
end
