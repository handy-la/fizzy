require "test_helper"

class SingleTenantSignupConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "concurrent first signups create only one account" do
    Account.delete_all
    identity = identities(:kevin)
    ready = Queue.new
    start = Queue.new
    threads = []
    tenants = Queue.new

    with_multi_tenant_mode(false) do
      threads = 2.times.map do |index|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            signup = Signup.new(full_name: "Owner #{index}", identity: identity, skip_account_seeding: true)
            signup.define_singleton_method(:create_tenant) do
              tenants << index
              10000 + index
            end
            ready << true
            start.pop
            signup.complete
          end
        ensure
          Current.reset
        end
      end

      2.times { ready.pop }
      2.times { start << true }
      results = threads.map(&:value)

      assert_equal [ false, true ], results.sort_by(&:to_s)
      assert_equal 1, tenants.size
      assert_equal 1, Account.count
      assert_equal 1, Account.last.users.where(role: :owner).count
      assert_equal 1, Account.last.users.where(role: :system).count
    end
  ensure
    threads.each(&:join)
  end
end
