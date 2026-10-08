class ZipFile::Reader::IO
  DEFLATED = 8

  # Deflate can expand data about 1000 times, so a read inflates at most this many
  # compressed bytes at once. Stored entries do not expand and read as requested.
  CHUNK_SIZE = 64.kilobytes

  def initialize(entry, io)
    @entry = entry
    @io = io
    rewind
  end

  def read(length = nil, buffer = nil)
    data = length ? extract(length) : extract_all
    return nil if data.nil?

    if buffer
      buffer.replace(data)
      buffer
    else
      data
    end
  end

  def eof?
    @extractor.eof?
  end

  def rewind
    @extractor = @entry.extractor_from(@io)
    @bytes_read = 0
    0
  end

  def size
    @entry.uncompressed_size
  end

  private
    def extract(length)
      return nil if @extractor.eof?

      @extractor.extract(deflated? ? [ length, CHUNK_SIZE ].min : length)&.tap do |data|
        @bytes_read += data.bytesize

        if @bytes_read > size
          raise ZipFile::LimitExceededError, "#{@entry.filename} expands beyond its declared #{size} bytes"
        end
      end
    end

    def extract_all
      chunks = []

      while chunk = extract(CHUNK_SIZE)
        chunks << chunk
      end

      chunks.join
    end

    def deflated?
      @entry.storage_mode == DEFLATED
    end
end
