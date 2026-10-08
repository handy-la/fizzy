# ZipKit buffers the whole tail before checking counts, and buffers the declared ZIP64
# EOCD size. Keep its entry parser, but validate metadata before either allocation.
class ZipFile::Reader::Structure < ZipKit::FileReader
  def read_zip_structure(io:, limits: nil)
    eocd_offset = get_eocd_offset(io, io.size)
    zip64_offset = get_zip64_eocd_location(io, eocd_offset)

    entry_count, directory_offset, directory_size = if zip64_offset
      read_zip64_directory(io, zip64_offset, eocd_offset - 20)
    else
      num_files_and_central_directory_offset(io, eocd_offset)
    end

    limits&.validate_directory!(entry_count: entry_count, byte_size: directory_size)
    validate_directory_range(directory_offset, directory_size, entry_count, zip64_offset || eocd_offset)

    seek(io, directory_offset)
    directory = StringIO.new(read_n(io, directory_size))
    Array.new(entry_count) { read_cdir_entry(directory) }
  end

  private
    def read_zip64_directory(io, offset, locator_offset)
      if offset > locator_offset - 56
        raise InvalidStructure, "ZIP64 EOCD is outside the archive"
      end

      seek(io, offset)
      assert_signature(io, 0x06064b50)
      record_size = read_8b(io)

      if record_size < 44 || record_size > locator_offset - offset - 12
        raise InvalidStructure, "ZIP64 EOCD has an invalid size"
      end

      # Only these fixed fields are needed. Never buffer the extensible data sector.
      _made_by, _version, disk, directory_disk, disk_entries, entries, size, location = read_n(io, 44).unpack("vvVVQ<Q<Q<Q<")

      if disk != 0 || directory_disk != 0 || disk_entries != entries
        raise UnsupportedFeature, "The archive spans multiple disks"
      end

      [ entries, location, size ]
    end

    def validate_directory_range(offset, size, entries, directory_end)
      if offset > directory_end || size > directory_end - offset || entries > size / 46
        raise InvalidStructure, "ZIP central directory is outside the archive or too small for its entries"
      end
    end
end
