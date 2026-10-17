require "test_helper"

# Handy #1204: two members upload an avatar at the same time while the account
# has room for only one. The account lock taken before the quota read lets
# only one fit. Regression: without the lock both read the same baseline.
class User::AvatarQuotaConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @account = Account.create!(name: "Concurrent avatar quota")
    @identities = 2.times.map { |i| Identity.create!(email_address: "avatar-quota-#{i}-#{@account.id}@example.test") }
    @users = @identities.map { |identity| @account.users.create!(name: "Member", identity: identity) }
    @size = File.size(file_fixture("avatar.png"))
    @limit = @account.storage_bytes_allowed
    Storage::Entry.record(account: @account, delta: @limit - @size - @account.bytes_used_exact, operation: "attach")
  end

  teardown do
    blob_ids = ActiveStorage::Attachment.where(record: @users).pluck(:blob_id)
    Current.with_account(@account) { @account.destroy! }
    ActiveStorage::Blob.where(id: blob_ids).find_each(&:purge)
    @identities.each(&:destroy!)
  end

  test "concurrent avatar uploads near the limit charge only the one that fits" do
    ready = Queue.new
    start = Queue.new
    threads = @users.map do |user|
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          Current.with_account(@account) do
            upload = Rack::Test::UploadedFile.new(file_fixture("avatar.png"), "image/png")
            ready << true
            start.pop
            User.find(user.id).update!(avatar: upload)
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
    assert_equal 1, ActiveStorage::Attachment.where(record: @users).count
    assert_equal @limit, @account.reload.bytes_used_exact
  ensure
    threads&.each(&:join)
  end
end
