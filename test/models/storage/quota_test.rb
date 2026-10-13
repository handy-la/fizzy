require "test_helper"

# Handy #967: ActionText embeds may reuse a blob, and each tracked attachment
# charges blob.byte_size again. The account limit is decided on the attachment,
# under the account lock, for every create and update path. Authoring answers
# and RED evidence: docs/test-audits/handy-967.md.
class Storage::QuotaTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:david)
    @account = accounts("37s")
    Current.account = @account
    @board = @account.boards.create!(name: "Quota", creator: users(:david))
    @blob = upload_moon
    @embed = embed_html(@blob)
    @first = @board.cards.create!(title: "First", creator: users(:david), description: "<p>#{@embed}</p>")
  end

  test "reusing an embedded blob cannot charge past the limit, and removing one releases its bytes" do
    fill_until_remaining @blob.byte_size - 1
    second = @board.cards.create!(title: "Second", creator: users(:david))

    assert_no_difference -> { Storage::Entry.count } do
      error = assert_raises(ActiveRecord::RecordNotSaved) { second.update!(description: "<p>#{@embed}</p>") }
      assert_kind_of Storage::QuotaExceeded, error
    end
    assert_equal 0, second.reload.description.embeds.count
    assert_equal storage_limit - @blob.byte_size + 1, @account.reload.bytes_used_exact

    # Per-attachment policy: removing one embed frees blob.byte_size, so the
    # same reuse then fits.
    @first.update!(description: "<p>No image</p>")
    assert_equal storage_limit - 2 * @blob.byte_size + 1, @account.reload.bytes_used_exact

    second.update!(description: "<p>#{@embed}</p>")
    assert_equal storage_limit - @blob.byte_size + 1, @account.reload.bytes_used_exact
  end

  test "a comment cannot reuse an embedded blob past the limit on create or update" do
    fill_until_remaining 0
    card = @board.cards.create!(title: "Commented", creator: users(:david), status: "published")

    assert_no_difference [ "Storage::Entry.count", "Comment.count" ] do
      assert_raises(ActiveRecord::RecordNotSaved) { card.comments.create!(body: "<p>#{@embed}</p>") }
    end

    comment = card.comments.create!(body: "<p>Text only</p>")
    assert_no_difference -> { Storage::Entry.count } do
      assert_raises(ActiveRecord::RecordNotSaved) { comment.update!(body: "<p>#{@embed}</p>") }
    end
    assert_equal "Text only", comment.reload.body.to_plain_text
    assert_equal storage_limit, @account.reload.bytes_used_exact
  end

  test "an edit at the limit is accepted when its net delta does not grow" do
    other = upload_moon
    second = @board.cards.create!(title: "Second", creator: users(:david), description: "<p>#{embed_html(other)}</p>")
    fill_until_remaining 0

    @first.update!(title: "Renamed")
    @first.update!(description: "<p>#{embed_html(other)}</p>")

    assert_equal [ other.id ], @first.reload.description.embeds.map(&:blob_id)
    assert_equal storage_limit, @account.reload.bytes_used_exact
  end

  # Rails saves the rich text in after_update and removes the image in
  # after_save, so only a check over the whole save sees this net delta.
  test "an edit at the limit may swap the card image for an embed of the same size" do
    other = upload_moon
    @board.cards.create!(title: "Second", creator: users(:david), description: "<p>#{embed_html(other)}</p>")
    card = @board.cards.create!(title: "With image", creator: users(:david))
    card.image.attach(upload_moon)
    fill_until_remaining 0

    card.update!(image: nil, description: "<p>#{embed_html(other)}</p>")

    assert_not card.reload.image.attached?
    assert_equal [ other.id ], card.description.embeds.map(&:blob_id)
    assert_equal storage_limit, @account.reload.bytes_used_exact
  end

  test "attaching a reserved direct upload at the limit is accepted because it was already charged" do
    blob = nil
    Storage::UploadReservation.reserve(account: @account, identity: identities(:david),
      attributes: { filename: "hello.png", byte_size: 5, checksum: Digest::MD5.base64digest("hello"), content_type: "image/png" }) { |reserved| blob = reserved }
    blob.upload(StringIO.new("hello"), identify: false)
    fill_until_remaining 0

    @first.image.attach(blob)

    assert @first.reload.image.attached?
    assert_equal storage_limit, @account.reload.bytes_used_exact
  end

  private
    def storage_limit
      @account.respond_to?(:storage_limit) ? @account.storage_limit : Storage::UploadReservation::DEFAULT_ACCOUNT_BYTES
    end

    def fill_until_remaining(bytes)
      Storage::Entry.record(account: @account, delta: storage_limit - bytes - @account.reload.bytes_used_exact, operation: "attach")
    end

    def upload_moon
      ActiveStorage::Blob.create_and_upload!(io: file_fixture("moon.jpg").open, filename: "moon.jpg", content_type: "image/jpeg")
    end

    def embed_html(blob)
      ActionText::Attachment.from_attachable(blob).to_html
    end
end
