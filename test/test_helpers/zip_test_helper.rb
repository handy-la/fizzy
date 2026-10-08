module ZipTestHelper
  CENTRAL_DIRECTORY_SIGNATURE = [ 0x02014b50 ].pack("V")

  private

  # Forges the uncompressed size that the central directory declares for one entry.
  # The central directory follows every entry, so its copy of the name is the last one.
  def declare_uncompressed_size(path, filename, size)
    bytes = File.binread(path)
    header = bytes.rindex(filename) - 46

    unless bytes.byteslice(header, 4) == CENTRAL_DIRECTORY_SIGNATURE && bytes.byteslice(header + 28, 2).unpack1("v") == filename.bytesize
      raise "No central directory entry for #{filename}"
    end

    bytes[header + 24, 4] = [ size ].pack("V")
    File.binwrite(path, bytes)
  end
end
