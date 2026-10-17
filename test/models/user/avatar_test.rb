require "test_helper"

class User::AvatarTest < ActiveSupport::TestCase
  test "avatar_thumbnail returns variant for variable images" do
    users(:david).avatar.attach(io: File.open(file_fixture("moon.jpg")), filename: "moon.jpg", content_type: "image/jpeg")

    assert users(:david).avatar.variable?
    assert_equal users(:david).avatar.variant(:thumb).blob, users(:david).avatar_thumbnail.blob
  end

  test "avatar_thumbnail returns original blob for non-variable images" do
    users(:david).avatar.attach(io: File.open(file_fixture("avatar.svg")), filename: "avatar.svg", content_type: "image/svg+xml")

    assert_not users(:david).avatar.variable?
    assert_equal users(:david).avatar.blob, users(:david).avatar_thumbnail.blob
  end

  test "allows valid image content types" do
    users(:david).avatar.attach(io: File.open(file_fixture("moon.jpg")), filename: "test.jpg", content_type: "image/jpeg")

    assert users(:david).valid?
  end

  test "rejects SVG uploads" do
    users(:david).avatar.attach(io: File.open(file_fixture("avatar.svg")), filename: "avatar.svg")

    assert_not users(:david).valid?
    assert_includes users(:david).errors[:avatar], "must be a JPEG, PNG, GIF, or WebP image"
  end

  test "thumb variant is processed immediately on attachment" do
    users(:david).avatar.attach(io: File.open(file_fixture("avatar.png")), filename: "avatar.png", content_type: "image/png")

    assert users(:david).avatar.variant(:thumb).processed?
  end

  test "rejects images that are too wide" do
    users(:david).avatar.attach(io: File.open(file_fixture("avatar.png")), filename: "avatar.png", content_type: "image/png")
    users(:david).avatar.blob.update!(metadata: { analyzed: true, width: 5000, height: 100 })

    assert_not users(:david).valid?
    assert_includes users(:david).errors[:avatar], "width must be less than #{User::Avatar::MAX_AVATAR_DIMENSIONS[:width]}px"
  end

  test "rejects images that are too tall" do
    users(:david).avatar.attach(io: File.open(file_fixture("avatar.png")), filename: "avatar.png", content_type: "image/png")
    users(:david).avatar.blob.update!(metadata: { analyzed: true, width: 100, height: 5000 })

    assert_not users(:david).valid?
    assert_includes users(:david).errors[:avatar], "height must be less than #{User::Avatar::MAX_AVATAR_DIMENSIONS[:height]}px"
  end

  test "accepts images within dimension limits" do
    users(:david).avatar.attach(io: File.open(file_fixture("avatar.png")), filename: "avatar.png", content_type: "image/png")
    users(:david).avatar.blob.update!(metadata: { analyzed: true, width: 4096, height: 4096 })

    assert users(:david).valid?
  end

  # Handy #1204. Contract: User::Avatar refuses an avatar over
  # MAX_AVATAR_BYTES before the image analyzer reads it, and charges an
  # accepted upload to the account's storage ledger under its limit.
  # Regression: dropping the size guard (or moving it after has_one_attached's
  # immediate analysis) runs the analyzer; dropping the ledger charge leaves
  # bytes_used_exact unchanged. The dimension tests above only cover pixels.
  # No seam: the tests use the model's public update path.
  test "rejects an avatar over the byte limit before analyzing it" do
    ActiveStorage::Analyzer::ImageAnalyzer::Vips.any_instance.expects(:metadata).never
    user = users(:david)

    assert_no_difference -> { ActiveStorage::Blob.count } do
      assert_not user.update(avatar: oversized_avatar)
    end
    assert_includes user.errors[:avatar], "must be smaller than #{User::Avatar::MAX_AVATAR_BYTES / 1.megabyte} MB"
  end

  test "charges an uploaded avatar to the account storage and releases it on removal" do
    user = users(:david)
    account = user.account
    before = account.bytes_used_exact

    assert user.update(avatar: avatar_upload)
    size = user.avatar.blob.byte_size
    assert_equal before + size, account.reload.bytes_used_exact

    user.avatar.destroy
    assert_equal before, account.reload.bytes_used_exact
  end

  test "rejects an avatar that would exceed the account storage limit" do
    user = users(:david)
    account = user.account
    size = File.size(file_fixture("avatar.png"))
    Storage::Entry.record(account: account, delta: account.storage_bytes_allowed - account.bytes_used_exact - size + 1, operation: "attach")
    usage = account.bytes_used_exact

    assert_no_difference -> { ActiveStorage::Blob.count } do
      assert_raises(Storage::QuotaExceeded) { user.update(avatar: avatar_upload) }
    end
    assert_equal usage, account.reload.bytes_used_exact
    assert_not user.reload.avatar.attached?
  end

  private
    def avatar_upload
      Rack::Test::UploadedFile.new(file_fixture("avatar.png"), "image/png")
    end

    def oversized_avatar
      file = Tempfile.new([ "avatar", ".png" ], binmode: true)
      file.write(File.binread(file_fixture("avatar.png")))
      file.write("\0" * (User::Avatar::MAX_AVATAR_BYTES + 1 - file.size))
      file.rewind
      Rack::Test::UploadedFile.new(file.path, "image/png")
    end
end
