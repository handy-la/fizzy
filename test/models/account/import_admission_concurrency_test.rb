require "test_helper"

class Account::ImportAdmissionConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @account = Account.create!(name: "Import quota race")
    @identities = 2.times.map { |index| Identity.create!(email_address: "import-race-#{@account.id}-#{index}@example.test") }
  end

  teardown do
    Account::Import::Admission.where(identity: @identities).delete_all
    @account.destroy!
    @identities.each(&:destroy!)
  end

  test "one identity can claim only one import across concurrent requests" do
    outcomes = race([ @identities.first, @identities.first ]) do |identity|
      Account::Import::Admission.claim(identity: identity)
      :accepted
    rescue Account::Import::Admission::Rejected
      :rejected
    end
    assert_equal [ :accepted, :rejected ], outcomes.sort
    assert_equal 1, Account::Import::Admission.unfinished.where(identity: @identities.first).count
  end

  test "account reservations serialize across identities and leave no overdraw" do
    outcomes = race(@identities) do |identity|
      admission = Account::Import::Admission.claim(identity: identity)
      admission.reserve(account: Account.find(@account.id), bytes: 600.megabytes)
      :accepted
    rescue Account::Import::InsufficientStorageSpaceError
      :rejected
    end
    assert_equal [ :accepted, :rejected ], outcomes.sort
    assert_equal 600.megabytes, @account.reload.bytes_used_exact
    assert_equal 600.megabytes, Account::Import::Admission.where(account: @account).sum(:reserved_bytes)
  end

  private
    def race(identities)
      ready = Queue.new
      start = Queue.new
      threads = identities.map do |identity|
        Thread.new do
          ApplicationRecord.connection_pool.with_connection do
            ready << true
            start.pop
            yield Identity.find(identity.id)
          end
        end
      end
      identities.size.times { ready.pop }
      identities.size.times { start << true }
      threads.map(&:value)
    ensure
      threads&.each(&:join)
    end
end
