require "test_helper"

# Handy #967: two mutations near the limit reuse the same embedded blob at the
# same time. The account lock taken before the quota read lets only one fit.
class Storage::QuotaConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @account = Account.create!(name: "Concurrent embed quota")
    @identity = Identity.create!(email_address: "embed-quota-#{@account.id}@example.test")
    @user = @account.users.create!(name: "Writer", identity: @identity)
    @board = Current.with_account(@account) { @account.boards.create!(name: "Quota", creator: @user) }
    Current.with_account(@account) do
      @blob = ActiveStorage::Blob.create_and_upload!(io: file_fixture("moon.jpg").open, filename: "moon.jpg", content_type: "image/jpeg")
      @embed = ActionText::Attachment.from_attachable(@blob).to_html
      @cards = 3.times.map { |i| @board.cards.create!(title: "Card #{i}", creator: @user) }
      @cards.first.update!(description: "<p>#{@embed}</p>")
    end
    limit = @account.respond_to?(:storage_limit) ? @account.storage_limit : Storage::UploadReservation::DEFAULT_ACCOUNT_BYTES
    Storage::Entry.record(account: @account, delta: limit - @blob.byte_size - @account.bytes_used_exact, operation: "attach")
    @limit = limit
  end

  teardown do
    Current.with_account(@account) { @account.destroy! }
    ActiveStorage::Blob.where(id: @blob.id).find_each(&:purge)
    @identity.destroy!
  end

  test "concurrent embeds near the limit charge only the delta that fits" do
    ready = Queue.new
    start = Queue.new
    threads = @cards.drop(1).map do |card|
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          Current.with_account(@account) do
            ready << true
            start.pop
            Card.find(card.id).update!(description: "<p>#{@embed}</p>")
            :accepted
          rescue ActiveRecord::RecordNotSaved
            :rejected
          end
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    outcomes = threads.map(&:value)

    assert_equal [ :accepted, :rejected ], outcomes.sort
    assert_equal 2, ActiveStorage::Attachment.where(blob_id: @blob.id).count
    assert_equal @limit, @account.reload.bytes_used_exact
  ensure
    threads&.each(&:join)
  end
end
