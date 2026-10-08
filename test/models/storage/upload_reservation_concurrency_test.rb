require "test_helper"

class Storage::UploadReservationConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @account = Account.create!(name: "Concurrent upload quota")
    @identities = 2.times.map { |i| Identity.create!(email_address: "quota-#{@account.id}-#{i}@example.test") }
    Storage::Entry.record(account: @account, delta: 10.gigabytes - 5, operation: "attach")
  end

  teardown do
    Storage::UploadReservation.where(account: @account).find_each(&:purge)
    ActiveStorage::Blob.where(account: @account).find_each(&:purge)
    @account.destroy!
    @identities.each(&:destroy!)
  end

  test "concurrent identities cannot reserve more than the remaining account quota" do
    ready = Queue.new
    start = Queue.new
    threads = @identities.map do |identity|
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          Current.with_account(@account) do
            ready << true
            start.pop
            begin
              Storage::UploadReservation.reserve(account: Account.find(@account.id), identity: identity,
                attributes: { filename: "hello.txt", byte_size: 5, checksum: Digest::MD5.base64digest("hello") }) { :accepted }
            rescue Storage::UploadReservation::Rejected
              :rejected
            end
          end
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    outcomes = threads.map(&:value)

    assert_equal [ :accepted, :rejected ], outcomes.sort
    assert_equal 1, Storage::UploadReservation.where(account: @account).count
    assert_equal 10.gigabytes, @account.reload.bytes_used_exact
  ensure
    threads&.each(&:join)
  end
end
