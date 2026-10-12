require "test_helper"
require "timeout"

class WebPush::PoolTest < ActiveSupport::TestCase
  Subscription = Struct.new(:id, :account_id, :delivery, :prepared) do
    def notification(**payload)
      prepared << id
      delivery
    end
  end

  setup do
    @pool = WebPush::Pool.new(invalid_subscription_handler: nil)
    @prepared = Queue.new
    @started = Queue.new
    @release = Queue.new
    @deliveries = []
  end

  teardown do
    200.times { @release << true }
    @pool.shutdown
  end

  test "one flooded account cannot occupy the workers of another account" do
    queue_for("flood", 120)
    queue_for("other", 1)
    starts = 6.times.map { pop(@started) }
    assert_equal 5, starts.count("flood")
    assert_equal 1, starts.count("other")
    assert_equal 101, @prepared.size
    6.times { @release << true }
    assert_equal "flood", pop(@started)
  end

  test "saturated account is logged before preparing rejected notifications" do
    warnings = []
    Rails.logger.stubs(:warn).with { |message| warnings << message; true }
    queue_for("flood", 101)
    assert_equal 100, @prepared.size
    assert warnings.any? { |message| message.include?("account=flood") && message.include?("account_budget") }
  end

  test "executor rejection is logged and releases the account budget" do
    @pool.delivery_pool.shutdown
    @pool.delivery_pool.wait_for_termination(1)
    warnings = []
    Rails.logger.stubs(:warn).with { |message| warnings << message; true }
    101.times { queue_for("rejected", 1) }
    assert_equal 101, @prepared.size
    assert_equal 101, warnings.count { |message| message.include?("account=rejected") && message.include?("executor_rejected") }
  end

  private
    def queue_for(account_id, count)
      subscriptions = count.times.map do |index|
        delivery = Object.new
        started, release = @started, @release
        delivery.define_singleton_method(:deliver) do |connection:|
          started << account_id
          release.pop
        end
        @deliveries << delivery
        Subscription.new(index.to_s, account_id, delivery, @prepared)
      end
      relation = Object.new
      relation.define_singleton_method(:find_each) { |&block| subscriptions.each(&block) }
      relation.define_singleton_method(:each) { |&block| subscriptions.each(&block) }
      @pool.queue({}, relation)
    end

    def pop(queue)
      Timeout.timeout(5) { queue.pop }
    end
end
