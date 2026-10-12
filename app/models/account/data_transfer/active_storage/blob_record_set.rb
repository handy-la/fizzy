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

    def import_batch(files)
      batch_data = files.filter_map do |file|
        data = load(file)
        if measured = verified_attributes(data)
          data.slice(*attributes).except("byte_size", "checksum", "metadata").merge(measured).merge(
            "account_id" => account.id,
            "key" => ::ActiveStorage::Blob.generate_unique_secure_token(length: ::ActiveStorage::Blob::MINIMUM_TOKEN_LENGTH),
            "service_name" => ::ActiveStorage::Blob.service.name
          )
        end
      end

      model.insert_all!(batch_data)
    end

    def check_record(file_path)
      super
      data = load(file_path)
      validate_declared_size(data)
      portable_metadata(data["metadata"])
      if path = storage_path(data)
        declared_entry_size = zip.read(path) { |stream| stream.size }
        unless declared_entry_size == data["byte_size"]
          raise IntegrityError, "Blob size does not match its storage entry"
        end
      end
    rescue JSON::ParserError => error
      raise IntegrityError, error.message
    end

    def verified_attributes(data)
      validate_declared_size(data)

      if path = storage_path(data)
        measured_attributes(data, path)
      end
    end

    def storage_path(data)
      path = "storage/#{data.fetch('key')}"
      if zip.exists?(path)
        path
      elsif referenced_blob_ids.include?(data["id"])
        raise IntegrityError, "Blob #{data['id']} has no storage file"
      end
    end

    def referenced_blob_ids
      @referenced_blob_ids ||= %w[active_storage_attachments active_storage_variant_records].each_with_object(Set.new) do |table, ids|
        zip.glob("data/#{table}/*.json").each { |file| ids << load(file)["blob_id"] }
      end
    end

    def with_zip(zip)
      @referenced_blob_ids = nil
      super
    end

    def measured_attributes(data, path)
      byte_size = 0
      checksum = Digest::MD5.new

      zip.read(path) do |stream|
        while chunk = stream.read(64.kilobytes)
          byte_size += chunk.bytesize
          checksum.update(chunk)
        end
      end

      checksum = checksum.base64digest
      unless byte_size == data["byte_size"] && checksum == data["checksum"]
        raise IntegrityError, "Blob #{data['id']} size or checksum does not match its storage file"
      end

      # Portable display metadata never supplies storage authority. Import
      # completion issues local reservations from these measured attributes.
      { "byte_size" => byte_size, "checksum" => checksum, "metadata" => portable_metadata(data["metadata"]) }
    end

    def portable_metadata(metadata)
      metadata = JSON.parse(metadata) if metadata.is_a?(String)
      metadata.is_a?(Hash) ? metadata.slice(*PORTABLE_METADATA) : {}
    rescue JSON::ParserError => error
      raise IntegrityError, error.message
    end

    def validate_declared_size(data)
      unless data["byte_size"].is_a?(Integer) && data["byte_size"] >= 0
        raise IntegrityError, "Blob #{data['id']} byte_size must be a nonnegative integer"
      end
    end
end
