class Account::DataTransfer::ActiveStorage::BlobRecordSet < Account::DataTransfer::RecordSet
  PORTABLE_METADATA = %w[identified analyzed width height duration angle display_aspect_ratio audio video].freeze

  def initialize(account)
    super(
      account: account,
      model: ::ActiveStorage::Blob,
      attributes: ::ActiveStorage::Blob.column_names - %w[service_name]
    )
  end

  private
    def records
      ::ActiveStorage::Blob.where(account: account).where.not(id: excluded_blob_ids)
    end

    def excluded_blob_ids
      ::ActiveStorage::Attachment.where(account: account, record_type: INTERNAL_RECORD_TYPES).select(:blob_id)
    end

    def check_record(file_path)
      super
      data = load(file_path)
      size = data["byte_size"]
      storage_file = "storage/#{data['key']}"
      actual_size = zip.exists?(storage_file) ? zip.read(storage_file) { |stream| stream.size } : 0
      unless data["metadata"].is_a?(Hash)
        raise IntegrityError, "Blob metadata must be an object"
      end
      unless size.is_a?(Integer) && size >= 0 && size == actual_size
        raise IntegrityError, "Blob size does not match its storage entry"
      end
    end

    def import_batch(files)
      batch_data = files.map do |file|
        data = load(file)
        data.slice(*attributes).merge(
          "account_id" => account.id,
          "metadata" => portable_metadata(data["metadata"]),
          "key" => ::ActiveStorage::Blob.generate_unique_secure_token(length: ::ActiveStorage::Blob::MINIMUM_TOKEN_LENGTH),
          "service_name" => ::ActiveStorage::Blob.service.name,
          "metadata" => data.fetch("metadata", {}).except("quota_upload", "quota_identity_id", "quota_expires_at").merge(
            "quota_upload" => true, "quota_identity_id" => account.imports.first&.identity_id,
            "quota_expires_at" => Time.current.iso8601(6))
        )
      end

      model.insert_all!(batch_data)
    end

    def portable_metadata(metadata)
      metadata = JSON.parse(metadata) if metadata.is_a?(String)
      metadata.is_a?(Hash) ? metadata.slice(*PORTABLE_METADATA) : {}
    end
end
