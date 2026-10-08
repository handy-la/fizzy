require "test_helper"

class ZipFile::LimitsTest < ActiveSupport::TestCase
  test "accepts an archive within every limit" do
    zip = create_test_zip("data/card.json" => "{}", "storage/file" => "x" * 100)

    reader = ZipFile::Reader.new(zip, limits: limits)

    assert_equal 102, reader.uncompressed_size
  end

  test "rejects too many entries" do
    zip = create_test_zip("a" => "1", "b" => "2", "c" => "3")
    ZipKit::FileReader.any_instance.expects(:read_cdir_entry).never

    error = assert_raises(ZipFile::LimitExceededError) { ZipFile::Reader.new(zip, limits: limits(max_entries: 2)) }
    assert_match(/3 entries, the limit is 2/, error.message)
  end

  test "rejects an entry larger than the entry limit" do
    zip = create_test_zip("storage/file" => "x" * 101)

    error = assert_raises(ZipFile::LimitExceededError) { ZipFile::Reader.new(zip, limits: limits(max_entry_size: 100)) }
    assert_match(%r{storage/file expands to 101 bytes}, error.message)
  end

  test "applies the smaller limit to JSON entries" do
    zip = create_test_zip("data/card.json" => "x" * 11)

    error = assert_raises(ZipFile::LimitExceededError) { ZipFile::Reader.new(zip, limits: limits(max_json_entry_size: 10)) }
    assert_match(%r{data/card.json expands to 11 bytes, the limit is 10}, error.message)
  end

  test "rejects an archive whose total uncompressed size is above the limit" do
    zip = create_test_zip("a" => "x" * 60, "b" => "x" * 60)

    error = assert_raises(ZipFile::LimitExceededError) { ZipFile::Reader.new(zip, limits: limits(max_entry_size: 100, max_total_size: 100)) }
    assert_match(/ZIP expands to 120 bytes, the limit is 100/, error.message)
  end

  test "rejects an entry with an extreme compression ratio" do
    zip = create_test_zip("storage/zeros" => "\0" * 2.megabytes)

    error = assert_raises(ZipFile::LimitExceededError) { ZipFile::Reader.new(zip, limits: limits) }
    assert_match(%r{storage/zeros has a compression ratio above 100:1}, error.message)
  end

  test "rejects many small entries whose sum has an extreme compression ratio" do
    zip = create_test_zip(4.times.to_h { |index| [ "storage/zeros#{index}", "\0" * 512.kilobytes ] })

    error = assert_raises(ZipFile::LimitExceededError) { ZipFile::Reader.new(zip, limits: limits) }
    assert_match(/ZIP has a compression ratio above 100:1/, error.message)
  end

  test "does not apply the compression ratio to small entries" do
    zip = create_test_zip("data/padding.json" => " " * 512.kilobytes)

    assert_nothing_raised { ZipFile::Reader.new(zip, limits: limits) }
  end

  private
    def limits(**overrides)
      ZipFile::Limits.new(
        max_entries: 10, max_entry_size: 10.megabytes, max_json_entry_size: 1.megabyte,
        max_total_size: 20.megabytes, max_compression_ratio: 100, **overrides
      )
    end

    def create_test_zip(files)
      tempfile = Tempfile.new([ "test", ".zip" ])
      tempfile.binmode

      writer = ZipFile::Writer.new(tempfile)
      files.each { |path, content| writer.add_file(path, content) }
      writer.close

      tempfile.rewind
      tempfile
    end
end
