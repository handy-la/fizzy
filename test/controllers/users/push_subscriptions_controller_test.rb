require "test_helper"

class Users::PushSubscriptionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as :david
    stub_web_push_dns_resolution
  end

  test "create new push subscription" do
    subscription_params = { "endpoint" => "https://fcm.googleapis.com/fcm/send/abc123", "p256dh_key" => "123", "auth_key" => "456" }

    post user_push_subscriptions_path(users(:david)),
      params: { push_subscription: subscription_params }, headers: { "HTTP_USER_AGENT" => "Mozilla/5.0" }

    assert_response :no_content

    assert_equal subscription_params, users(:david).push_subscriptions.last.attributes.slice("endpoint", "p256dh_key", "auth_key")
    assert_equal "Mozilla/5.0", users(:david).push_subscriptions.last.user_agent
  end

  test "create as JSON" do
    subscription_params = { "endpoint" => "https://fcm.googleapis.com/fcm/send/abc123", "p256dh_key" => "123", "auth_key" => "456" }

    post user_push_subscriptions_path(users(:david)),
      params: { push_subscription: subscription_params }, headers: { "HTTP_USER_AGENT" => "Mozilla/5.0" }, as: :json

    assert_response :created
  end

  test "create as JSON for duplicate subscription" do
    subscription_params = { "endpoint" => "https://fcm.googleapis.com/fcm/send/abc123", "p256dh_key" => "123", "auth_key" => "456" }

    users(:david).push_subscriptions.create!(subscription_params)

    assert_no_difference -> { Push::Subscription.count } do
      post user_push_subscriptions_path(users(:david)),
        params: { push_subscription: subscription_params }, as: :json
    end

    assert_response :created
  end

  test "destroy as JSON" do
    subscription = users(:david).push_subscriptions.create!(
      endpoint: "https://fcm.googleapis.com/fcm/send/abc123",
      p256dh_key: "123",
      auth_key: "456"
    )

    assert_difference -> { Push::Subscription.count }, -1 do
      delete user_push_subscription_path(users(:david), subscription), as: :json
    end

    assert_response :no_content
  end

  test "sixth device is rejected but token rotation of an existing client succeeds" do
    5.times do |index|
      post_subscription(index, client_id: "client-#{index}")
      assert_response :created
    end

    assert_no_difference -> { users(:david).push_subscriptions.count } do
      post_subscription(5, client_id: "sixth-client")
      assert_response :too_many_requests
      post_subscription(6, client_id: "client-0")
      assert_response :created
    end
    assert_not users(:david).push_subscriptions.exists?(endpoint: push_endpoint(0))
    assert users(:david).push_subscriptions.exists?(endpoint: push_endpoint(6))
  end

  test "rotating tokens and IPs share a user rate limit and another user retains capacity" do
    store = Users::PushSubscriptionsController.cache_store
    memory = ActiveSupport::Cache::MemoryStore.new
    store.define_singleton_method(:increment) { |*args, **options| memory.increment(*args, **options) }

    10.times do |index|
      post_subscription(index, client_id: "same-client", ip: "198.51.100.#{index + 1}")
      assert_response :created
    end
    assert_no_difference -> { Push::Subscription.count } do
      post_subscription(11, client_id: "new-client", ip: "203.0.113.1")
      assert_response :too_many_requests
    end
    assert_equal 1, users(:david).push_subscriptions.count
    logout_and_sign_in_as :kevin
    post user_push_subscriptions_path(users(:kevin)),
      params: { push_subscription: { endpoint: push_endpoint(12), p256dh_key: "key", auth_key: "auth" } }, as: :json
    assert_response :created

    travel 11.minutes do
      logout_and_sign_in_as :david
      post_subscription(13, client_id: "same-client")
      assert_response :created
    end
  ensure
    store.singleton_class.remove_method(:increment)
  end

  test "invalid replacement preserves the working subscription" do
    post_subscription(0, client_id: "same-client")
    assert_no_difference -> { Push::Subscription.count } do
      post user_push_subscriptions_path(users(:david)), params: { push_subscription: {
        endpoint: "https://attacker.example.com/push", p256dh_key: "key", auth_key: "auth", client_id: "same-client"
      } }, as: :json
      assert_response :unprocessable_entity
    end
    assert users(:david).push_subscriptions.exists?(endpoint: push_endpoint(0))
  end

  test "destroy a push subscription" do
    subscription = users(:david).push_subscriptions.create!(
      endpoint: "https://fcm.googleapis.com/fcm/send/abc123",
      p256dh_key: "123",
      auth_key: "456"
    )

    assert_difference -> { Push::Subscription.count }, -1 do
      delete user_push_subscription_path(users(:david), subscription)
      assert_redirected_to user_push_subscriptions_path(users(:david))
    end
  end

  test "rejects subscription with non-permitted endpoint" do
    subscription_params = { "endpoint" => "https://attacker.example.com/steal", "p256dh_key" => "123", "auth_key" => "456" }

    assert_no_difference -> { Push::Subscription.count } do
      post user_push_subscriptions_path(users(:david)),
        params: { push_subscription: subscription_params }
    end

    assert_response :unprocessable_entity
  end

  test "rejects subscription with endpoint resolving to private IP" do
    stub_dns_resolution("192.168.1.1")

    subscription_params = { "endpoint" => "https://fcm.googleapis.com/fcm/send/abc123", "p256dh_key" => "123", "auth_key" => "456" }

    assert_no_difference -> { Push::Subscription.count } do
      post user_push_subscriptions_path(users(:david)),
        params: { push_subscription: subscription_params }
    end

    assert_response :unprocessable_entity
  end

  private
    def push_endpoint(index)
      "https://fcm.googleapis.com/fcm/send/quota-#{index}"
    end

    def post_subscription(index, client_id:, ip: "198.51.100.1")
      post user_push_subscriptions_path(users(:david)), params: { push_subscription: {
        endpoint: push_endpoint(index), p256dh_key: "key-#{index}", auth_key: "auth-#{index}", client_id: client_id
      } }, headers: { "REMOTE_ADDR" => ip }, as: :json
    end
end
