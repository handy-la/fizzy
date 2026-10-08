require "test_helper"

class ZipFileTest < ActiveSupport::TestCase
  include ZipTestHelper

  test "writer adds files with content" do
    tempfile = Tempfile.new([ "test", ".zip" ])
    tempfile.binmode

    writer = ZipFile::Writer.new(tempfile)
    writer.add_file("hello.txt", "Hello, World!")
    writer.close

    assert writer.exists?("hello.txt")
    assert_not writer.exists?("missing.txt")
  end

  test "writer adds files with block" do
    tempfile = Tempfile.new([ "test", ".zip" ])
    tempfile.binmode

    writer = ZipFile::Writer.new(tempfile)
    writer.add_file("hello.txt") { |sink| sink.write("Hello, World!") }
    writer.close

    assert writer.exists?("hello.txt")
  end

  test "writer globs entries" do
    tempfile = Tempfile.new([ "test", ".zip" ])
    tempfile.binmode

    writer = ZipFile::Writer.new(tempfile)
    writer.add_file("docs/readme.txt", "Readme")
    writer.add_file("docs/guide.txt", "Guide")
    writer.add_file("images/logo.png", "PNG data")
    writer.close

    assert_equal [ "docs/guide.txt", "docs/readme.txt" ], writer.glob("docs/*.txt")
    assert_equal [ "images/logo.png" ], writer.glob("**/*.png")
  end

  test "reader reads file content" do
    tempfile = create_test_zip("hello.txt" => "Hello, World!")

    reader = ZipFile::Reader.new(tempfile)
    content = reader.read("hello.txt")

    assert_equal "Hello, World!", content
  end

  test "reader reads file with block" do
    tempfile = create_test_zip("hello.txt" => "Hello, World!")

    reader = ZipFile::Reader.new(tempfile)
    content = nil
    reader.read("hello.txt") { |io| content = io.read }

    assert_equal "Hello, World!", content
  end

  test "reader raises for missing file" do
    tempfile = create_test_zip("hello.txt" => "Hello")

    reader = ZipFile::Reader.new(tempfile)

    assert_raises(ArgumentError) { reader.read("missing.txt") }
  end

  test "reader checks file existence" do
    tempfile = create_test_zip("hello.txt" => "Hello")

    reader = ZipFile::Reader.new(tempfile)

    assert reader.exists?("hello.txt")
    assert_not reader.exists?("missing.txt")
  end

  test "reader globs entries" do
    tempfile = create_test_zip(
      "docs/readme.txt" => "Readme",
      "docs/guide.txt" => "Guide",
      "images/logo.png" => "PNG"
    )

    reader = ZipFile::Reader.new(tempfile)

    assert_equal [ "docs/guide.txt", "docs/readme.txt" ], reader.glob("docs/*.txt")
  end

  test "reader io provides size" do
    tempfile = create_test_zip("hello.txt" => "Hello, World!")

    reader = ZipFile::Reader.new(tempfile)
    reader.read("hello.txt") do |io|
      assert_equal 13, io.size
    end
  end

  test "reader io supports rewind" do
    tempfile = create_test_zip("hello.txt" => "Hello, World!")

    reader = ZipFile::Reader.new(tempfile)
    reader.read("hello.txt") do |io|
      first_read = io.read
      io.rewind
      second_read = io.read

      assert_equal first_read, second_read
    end
  end

  test "reader io tracks eof" do
    tempfile = create_test_zip("hello.txt" => "Hello")

    reader = ZipFile::Reader.new(tempfile)
    reader.read("hello.txt") do |io|
      assert_not io.eof?
      io.read
      assert io.eof?
    end
  end

  test "reader raises InvalidFileError for non-zip file" do
    tempfile = Tempfile.new([ "not_a_zip", ".zip" ])
    tempfile.write("this is not a zip file at all")
    tempfile.rewind

    assert_raises(ZipFile::InvalidFileError) { ZipFile::Reader.new(tempfile) }
  ensure
    tempfile&.close
    tempfile&.unlink
  end

  test "reader io stops an entry that expands beyond its declared size" do
    tempfile = create_test_zip("data/card.json" => "x" * 100)
    declare_uncompressed_size(tempfile.path, "data/card.json", 10)

    File.open(tempfile.path, "rb") do |file|
      reader = ZipFile::Reader.new(file)

      error = assert_raises(ZipFile::InvalidFileError) { reader.read("data/card.json") }
      assert_match(/expands beyond its declared 10 bytes/, error.message)
      assert_raises(ZipFile::InvalidFileError) { reader.read("data/card.json") { |io| io.read(1.megabyte) } }
    end
  end

  test "reader io inflates a deflated entry in bounded chunks" do
    tempfile = create_test_zip("data/random.json" => Random.new(42).bytes(2.megabytes))

    File.open(tempfile.path, "rb") do |file|
      ZipFile::Reader.new(file).read("data/random.json") do |io|
        chunk = io.read(5.megabytes)

        assert_operator chunk.bytesize, :>, 0
        assert_operator chunk.bytesize, :<, 1.megabyte
      end
    end
  end

  private
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
