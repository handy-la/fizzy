require "test_helper"

class ZipFile::StructureTest < ActiveSupport::TestCase
  class RecordingIO < StringIO
    attr_reader :read_lengths

    def initialize(bytes)
      super(bytes)
      @read_lengths = []
    end

    def read(length = nil)
      read_lengths << length
      super
    end
  end

  [ false, true ].each do |zip64|
    format = zip64 ? "ZIP64" : "ZIP"

    test "#{format} rejects declared entry count before parsing entries" do
      bytes = archive_bytes(zip64: zip64, count: 11)
      io = RecordingIO.new(bytes)
      _offset, directory_size = directory_location(bytes, zip64: zip64)
      ZipKit::FileReader.any_instance.expects(:read_cdir_entry).never

      error = assert_raises(ZipFile::LimitExceededError) { ZipFile::Reader.new(io, limits: limits) }
      assert_match(/11 entries, the limit is 10/, error.message)
      assert_not_includes io.read_lengths, directory_size
      assert_not_includes io.read_lengths, nil
    end

    test "#{format} rejects oversized central directory before parsing entries" do
      bytes = archive_bytes(zip64: zip64, directory_size: 256.megabytes + 1)
      io = RecordingIO.new(bytes)
      ZipKit::FileReader.any_instance.expects(:read_cdir_entry).never

      error = assert_raises(ZipFile::LimitExceededError) { ZipFile::Reader.new(io, limits: limits) }
      assert_match(/central directory/, error.message)
      assert_not_includes io.read_lengths, 256.megabytes + 1
      assert_not_includes io.read_lengths, nil
    end

    test "#{format} rejects central directory outside the archive" do
      bytes = archive_bytes(zip64: zip64, directory_offset: 2**32 - 1)

      assert_raises(ZipFile::InvalidFileError) { ZipFile::Reader.new(StringIO.new(bytes), limits: limits) }
    end

    test "#{format} reads only declared central directory bytes from remote storage" do
      bytes = archive_bytes(zip64: zip64, comment: "c" * 1_000)
      directory_offset, directory_size = directory_location(bytes, zip64: zip64)
      ranges = []
      remote = remote_archive(bytes, ranges)

      reader = ZipFile::Reader.new(remote, limits: limits)

      assert_equal "Hello", reader.read("hello.txt")
      assert_includes ranges, directory_offset..(directory_offset + directory_size - 1)
      assert_not_includes ranges, directory_offset..(bytes.bytesize - 1)
    end
  end

  test "ZIP64 never reads its arbitrary declared EOCD record size" do
    bytes = archive_bytes(zip64: true)
    zip64_offset = bytes.rindex([ 0x06064b50 ].pack("V"))
    bytes[zip64_offset + 4, 8] = [ 1.terabyte ].pack("Q<")
    io = RecordingIO.new(bytes)

    assert_raises(ZipFile::InvalidFileError) { ZipFile::Reader.new(io, limits: limits) }
    assert_not_includes io.read_lengths, 1.terabyte
  end

  test "rejects a directory size that ends inside an entry" do
    bytes = archive_bytes(directory_size: 46)

    assert_raises(ZipFile::InvalidFileError) { ZipFile::Reader.new(StringIO.new(bytes), limits: limits) }
  end

  test "a manipulated start offset does not trigger a read to the end" do
    bytes = archive_bytes(directory_offset: 0)
    io = RecordingIO.new(bytes)

    assert_raises(ZipFile::InvalidFileError) { ZipFile::Reader.new(io, limits: limits) }
    assert_not_includes io.read_lengths, nil
  end

  private
    def limits
      ZipFile::Limits.new(max_entries: 10, max_entry_size: 1.megabyte,
        max_json_entry_size: 1.megabyte, max_total_size: 1.megabyte, max_compression_ratio: 100)
    end

    def archive_bytes(zip64: false, count: nil, directory_size: nil, directory_offset: nil, comment: "")
      io = StringIO.new("".b)
      writer = ZipFile::Writer.new(io)
      writer.add_file("hello.txt", "Hello")
      writer.close
      bytes = io.string
      eocd_offset = bytes.rindex([ 0x06054b50 ].pack("V"))
      eocd = bytes.byteslice(eocd_offset, 22)
      original_count, original_size, original_offset = eocd.byteslice(10, 10).unpack("vVV")
      count ||= original_count
      directory_size ||= original_size
      directory_offset ||= original_offset
      eocd[20, 2] = [ comment.bytesize ].pack("v")

      if zip64
        record = [ 0x06064b50, 44, 45, 45, 0, 0, count, count, directory_size, directory_offset ].pack("VQ<vvVVQ<Q<Q<Q<")
        locator = [ 0x07064b50, 0, eocd_offset, 1 ].pack("VVQ<V")
        eocd[8, 12] = [ 0xFFFF, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF ].pack("vvVV")
        bytes.byteslice(0, eocd_offset) + record + locator + eocd + comment
      else
        eocd[8, 12] = [ count, count, directory_size, directory_offset ].pack("vvVV")
        bytes.byteslice(0, eocd_offset) + eocd + comment
      end
    end

    def directory_location(bytes, zip64:)
      if zip64
        offset = bytes.rindex([ 0x06064b50 ].pack("V"))
        size, location = bytes.byteslice(offset + 40, 16).unpack("Q<Q<")
      else
        offset = bytes.rindex([ 0x06054b50 ].pack("V"))
        size, location = bytes.byteslice(offset + 12, 8).unpack("VV")
      end
      [ location, size ]
    end

    def remote_archive(bytes, ranges)
      url = "https://zip.example.test/archive.zip"
      stub_request(:get, url).to_return do |request|
        first, last = request.headers.fetch("Range").delete_prefix("bytes=").split("-").map(&:to_i)
        range = first..last
        ranges << range
        { status: 206, body: bytes.byteslice(range), headers: { "Content-Range" => "bytes #{first}-#{last}/#{bytes.bytesize}" } }
      end
      ZipFile::RemoteIO.new(url)
    end
end
