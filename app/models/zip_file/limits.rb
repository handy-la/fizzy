class ZipFile::Limits
  # Small entries compress poorly or well without risk, so the ratio only applies above this size.
  RATIO_EXEMPT_SIZE = 1.megabyte

  attr_reader :max_entries, :max_entry_size, :max_json_entry_size, :max_total_size, :max_compression_ratio, :max_central_directory_size

  def initialize(max_entries:, max_entry_size:, max_json_entry_size:, max_total_size:, max_compression_ratio:, max_central_directory_size: 256.megabytes)
    @max_entries = max_entries
    @max_entry_size = max_entry_size
    @max_json_entry_size = max_json_entry_size
    @max_total_size = max_total_size
    @max_compression_ratio = max_compression_ratio
    @max_central_directory_size = max_central_directory_size
  end

  def validate_directory!(entry_count:, byte_size:)
    validate_entry_count!(entry_count)

    if byte_size > max_central_directory_size
      raise ZipFile::LimitExceededError, "ZIP central directory has #{byte_size} bytes, the limit is #{max_central_directory_size}"
    end
  end

  def validate!(entries)
    validate_entry_count!(entries.size)

    entries.each { |entry| validate_entry!(entry) }

    uncompressed_size = entries.sum(&:uncompressed_size)
    compressed_size = entries.sum(&:compressed_size)

    if uncompressed_size > max_total_size
      raise ZipFile::LimitExceededError, "ZIP expands to #{uncompressed_size} bytes, the limit is #{max_total_size}"
    end

    validate_ratio!("ZIP", uncompressed_size, compressed_size)
  end

  private
    def validate_entry_count!(count)
      if count > max_entries
        raise ZipFile::LimitExceededError, "ZIP has #{count} entries, the limit is #{max_entries}"
      end
    end

    def validate_entry!(entry)
      limit = entry.filename.end_with?(".json") ? max_json_entry_size : max_entry_size

      if entry.uncompressed_size > limit
        raise ZipFile::LimitExceededError, "#{entry.filename} expands to #{entry.uncompressed_size} bytes, the limit is #{limit}"
      end

      validate_ratio!(entry.filename, entry.uncompressed_size, entry.compressed_size)
    end

    def validate_ratio!(name, uncompressed_size, compressed_size)
      if uncompressed_size > RATIO_EXEMPT_SIZE && uncompressed_size > compressed_size * max_compression_ratio
        raise ZipFile::LimitExceededError, "#{name} has a compression ratio above #{max_compression_ratio}:1"
      end
    end
end
