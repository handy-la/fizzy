class Account::DataTransfer::ActiveStorage::AttachmentRecordSet < Account::DataTransfer::RecordSet
  # Imported blobs keep no quota_* metadata from the export. The server marks
  # the blobs of these untracked records so the account total counts them.
  CHARGED_RECORD_TYPES = %w[User].freeze

  def initialize(account)
    super(account: account, model: ::ActiveStorage::Attachment)
  end

  private
    def records
      ::ActiveStorage::Attachment.where(account: account)
        .where.not(record_type: INTERNAL_RECORD_TYPES)
    end

    def import_batch(files)
      super
      charge_imported_blobs(files.map { |file| File.basename(file, ".json") })
    end

    def charge_imported_blobs(attachment_ids)
      blob_ids = ::ActiveStorage::Attachment.where(id: attachment_ids, account: account, record_type: CHARGED_RECORD_TYPES).select(:blob_id)
      ::ActiveStorage::Blob.where(id: blob_ids, account: account).find_each do |blob|
        blob.update_columns(metadata: blob.metadata.merge("quota_upload" => true))
      end
    end
end
