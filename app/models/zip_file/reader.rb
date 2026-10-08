class ZipFile::Reader
  attr_reader :uncompressed_size

  def initialize(io, limits: nil)
    @io = io
    @reader = read_structure(limits)
    @uncompressed_size = @reader.sum(&:uncompressed_size)
  rescue ZipKit::FileReader::ReadError, ZipKit::FileReader::MissingEOCD, ZipKit::FileReader::UnsupportedFeature => e
    raise ZipFile::InvalidFileError, e.message
  end

  def read(file_path)
    entry = @reader.find { |e| e.filename == file_path }
    raise ArgumentError, "File not found in zip: #{file_path}" unless entry
    raise ArgumentError, "Cannot read directory entry: #{file_path}" if entry.filename.end_with?("/")

    if block_given?
      yield ZipFile::Reader::IO.new(entry, @io)
    else
      ZipFile::Reader::IO.new(entry, @io).read
    end
  end

  def glob(pattern)
    @reader.map(&:filename).select { |name| File.fnmatch(pattern, name) }.sort
  end

  def exists?(file_path)
    @reader.any? { |e| e.filename == file_path }
  end

  private
    def read_structure(limits)
      file_reader = ZipFile::Reader::Structure.new

      file_reader.read_zip_structure(io: @io, limits: limits).tap do |entries|
        limits&.validate!(entries)

        entries.each do |entry|
          entry.compressed_data_offset = file_reader.get_compressed_data_offset(io: @io, local_file_header_offset: entry.local_file_header_offset)
        end
      end
    end
end
