require "shellwords"

class Account::Import < ApplicationRecord
  class AlreadyInProgressError < StandardError; end
  class InsufficientStorageSpaceError < StandardError; end

  REQUIRED_STORAGE_SPACE_FACTOR = 2
  TRANSIENT_ERRORS = [ ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout,
    Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ETIMEDOUT ].freeze

  LIMITS = ZipFile::Limits.new(
    max_entries: 20_000,
    max_entry_size: 100.megabytes,
    max_json_entry_size: 1.megabyte,
    max_total_size: 1.gigabyte,
    max_compression_ratio: 50,
    max_central_directory_size: 4.megabytes
  )

  MAX_COMPRESSED_BYTES = 100.megabytes
  MAX_RECORDS = 10_000

  broadcasts_refreshes

  belongs_to :account
  belongs_to :identity
  has_one :admission, class_name: "Account::Import::Admission", foreign_key: :import_id

  has_one_attached :file, dependent: :purge_later

  enum :status, %w[ pending processing completed failed ].index_by(&:itself), default: :pending
  enum :failure_reason, %w[ conflict invalid_export insufficient_storage_space ].index_by(&:itself), prefix: :failed_due_to, scopes: false

  scope :expired, -> { where(completed_at: ...24.hours.ago).or(where(status: :failed, created_at: ...7.days.ago)) }

  def self.start(identity:, file:)
    import = nil
    started = false
    admission = Admission.claim(identity: identity)
    preflight(file)
    signup = Signup.new(identity: identity, full_name: "Import", skip_account_seeding: true)

    if signup.complete
      Current.set(account: signup.account) do
        reserve_upload(admission, signup.account, file)
        import = signup.account.imports.create!(identity: identity)
        admission.update!(import: import)
        import.file.attach(file)
        import.process_later
        started = true
        import
      end
    end
  ensure
    unless started
      import&.mark_as_failed(:invalid_export)
      signup&.cancel if signup&.account
      admission&.finish
    end
  end

  def self.cleanup
    where(status: :failed).find_each(&:purge_failed_files)
    expired.each(&:cleanup)
    Admission.where(finished_at: ..24.hours.ago).delete_all
  end

  def self.preflight(upload)
    unless upload.respond_to?(:tempfile) && upload.tempfile.size.positive?
      raise ZipFile::InvalidFileError, "a ZIP upload is required"
    end
    if upload.tempfile.size > MAX_COMPRESSED_BYTES
      raise Admission::Rejected.new(:content_too_large)
    end

    zip = ZipFile::Reader.new(upload.tempfile, limits: LIMITS)
    validate_record_budget(zip)
    bytes = upload.tempfile.size + zip.uncompressed_size
    if bytes > Admission.account_limit(Account.new) || bytes > Admission::MAX_IDENTITY_BYTES
      raise InsufficientStorageSpaceError, "import exceeds available quota"
    end
    upload.tempfile.rewind
    bytes
  end

  def self.reserve_upload(admission, account, upload)
    bytes = preflight(upload)
    ensure_disk_capacity(ActiveStorage::Blob.service, bytes * REQUIRED_STORAGE_SPACE_FACTOR)
    admission.reserve(account: account, bytes: bytes)
    upload.tempfile.rewind
  end

  def self.validate_record_budget(zip)
    if zip.glob("data/*.json").size > MAX_RECORDS
      raise ZipFile::LimitExceededError, "ZIP contains more than #{MAX_RECORDS} records"
    end
    unless zip.exists?("data/account.json")
      raise ZipFile::InvalidFileError, "ZIP has no account record"
    end
  end

  def self.ensure_disk_capacity(service, required)
    if service.respond_to?(:root)
      path = service.root.to_s
      path = File.dirname(path) until File.exist?(path) || path == File.dirname(path)
      ensure_capacity(required, available_storage_space(path))
    end
  end

  def self.ensure_capacity(required, available)
    unless available.is_a?(Integer) && available >= required
      raise InsufficientStorageSpaceError, "import needs ~#{ActiveSupport::NumberHelper.number_to_human_size(required)} free, found #{available || 'unknown'}"
    end
  end

  def self.available_storage_space(path)
    fields = `df -Pk #{Shellwords.escape(path)} 2>/dev/null`.lines.last.to_s.split
    capacity_index = fields.index { |field| field.match?(/\A\d+%\z/) }
    if capacity_index
      available_kilobytes = Integer(fields[capacity_index - 1], exception: false)
      available_kilobytes&.kilobytes
    end
  end

  def process_later
    Account::DataImportJob.perform_later(self)
  end

  def check(start: nil, callback: nil)
    processing!

    ZipFile.read_from(file.blob, limits: LIMITS) do |zip|
      ensure_sufficient_storage_space(zip)

      Account::DataTransfer::Manifest.new(account).each_record_set(start: start) do |record_set, last_id|
        record_set.check(from: zip, start: last_id, callback: callback)
      end
    end
  rescue Account::DataTransfer::RecordSet::ConflictError => e
    mark_as_failed(:conflict)
    raise e
  rescue Account::DataTransfer::RecordSet::IntegrityError, ZipFile::InvalidFileError => e
    mark_as_failed(:invalid_export)
    raise e
  rescue InsufficientStorageSpaceError => e
    mark_as_failed(:insufficient_storage_space)
    raise e
  rescue *TRANSIENT_ERRORS
    raise
  rescue => e
    mark_as_failed
    raise e
  end

  def process(start: nil, callback: nil)
    processing!

    ZipFile.read_from(file.blob, limits: LIMITS) do |zip|
      ensure_sufficient_storage_space(zip)

      Account::DataTransfer::Manifest.new(account).each_record_set(start: start) do |record_set, last_id|
        record_set.import(from: zip, start: last_id, callback: callback)
      end
    end

    add_importer_to_all_access_boards
    create_missing_user_settings
    reconcile_cards_count
    mark_completed
  rescue ZipFile::LimitExceededError => e
    mark_as_failed(:invalid_export)
    raise e
  rescue Account::DataTransfer::RecordSet::ConflictError => e
    mark_as_failed(:conflict)
    raise e
  rescue Account::DataTransfer::RecordSet::IntegrityError, ZipFile::InvalidFileError => e
    mark_as_failed(:invalid_export)
    raise e
  rescue InsufficientStorageSpaceError => e
    mark_as_failed(:insufficient_storage_space)
    raise e
  rescue *TRANSIENT_ERRORS
    raise
  rescue => e
    mark_as_failed
    raise e
  end

  def mark_as_failed(failure_reason = nil)
    with_lock do
      unless failed? || completed?
        update!(status: :failed, failure_reason: failure_reason)
        ImportMailer.failed(self).deliver_later
      end
    end
    purge_failed_files if failed?
  end

  def purge_failed_files
    Storage::UploadReservation.serialize_account(account) do
      discard_imported_records
      purge_archive
      admission&.finish
    end
  end

  def cleanup
    admission&.update!(import_id: nil)
    destroy
    account.destroy if failed?
  end

  private
    def ensure_sufficient_storage_space(zip)
      self.class.validate_record_budget(zip)
      if file.blob.byte_size > MAX_COMPRESSED_BYTES
        raise ZipFile::LimitExceededError, "compressed ZIP exceeds #{MAX_COMPRESSED_BYTES} bytes"
      end
      bytes = zip.uncompressed_size + file.blob.byte_size
      if path = ZipFile.path_on_disk(file.blob)
        self.class.ensure_capacity(bytes * REQUIRED_STORAGE_SPACE_FACTOR, available_storage_space(path))
      end
      self.admission ||= Admission.claim(identity: identity, import: self)
      admission.reserve(account: account, bytes: bytes)
    end

    def purge_archive
      if file.attached?
        blob = file.blob
        # Delete the object first and keep its key and charge if deletion fails.
        blob.delete
        file.attachment.delete
        blob.destroy!
        association(:file_attachment).reset
        association(:file_blob).reset
      end
    end

    def discard_imported_records
      Account::DataTransfer::Manifest.new(account).discard_records
      Storage::UploadReservation.where(account: account).delete_all
      account.reconcile_storage
      account.materialize_storage
    end

    def available_storage_space(path)
      self.class.available_storage_space(path)
    end

    def mark_completed
      Storage::UploadReservation.serialize_account(account) do
        # Bulk import bypasses attachment callbacks. Issue trusted local rows
        # before reconciliation; pending excludes attached blobs from the charge.
        internal_blob_ids = ActiveStorage::Attachment.where(account: account,
          record_type: Account::DataTransfer::RecordSet::INTERNAL_RECORD_TYPES).select(:blob_id)
        ActiveStorage::Blob.where(account: account).where.not(id: internal_blob_ids).find_each do |blob|
          Storage::UploadReservation.create_or_find_by!(blob: blob) do |reservation|
            reservation.account = account
            reservation.identity = identity
            reservation.byte_size = blob.byte_size
            reservation.expires_at = Storage::UploadReservation::DRAFT_RETENTION.from_now
          end
        end
        reconcile_account_storage
        charged = account.bytes_used_exact - (admission&.reserved_bytes || 0)
        if charged > Admission.account_limit(account) || charged > Admission::MAX_IDENTITY_BYTES
          raise InsufficientStorageSpaceError, "imported attachments exceed available quota"
        end
        purge_archive
        admission&.finish
        update!(status: :completed, completed_at: Time.current)
      end
      ImportMailer.completed(identity, account).deliver_later
    end

    def reconcile_cards_count
      account.update_column :cards_count, [ account.cards_count, account.cards.maximum(:number).to_i ].max
    end

    def add_importer_to_all_access_boards
      importer = account.users.find_by!(identity: identity)

      account.boards.all_access.find_each do |board|
        board.accesses.grant_to(importer)
      end
    end

    def create_missing_user_settings
      account.users.where.not(role: :system).where.missing(:settings).find_each(&:create_settings!)
    end

    def reconcile_account_storage
      account.boards.each(&:reconcile_storage)
      account.reconcile_storage
      account.materialize_storage
    end
end
