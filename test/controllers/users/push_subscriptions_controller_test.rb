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

    post user_push_subscriptions_path(users(:david)), params: { push_subscription: subscription_params }, as: :json

    assert_no_difference -> { Push::Subscription.count } do
      post user_push_subscriptions_path(users(:david)),
        params: { push_subscription: subscription_params }, as: :json
    end

    assert_response :created
  end

  test "logout removes subscriptions authorized by this session" do
    post user_push_subscriptions_path(users(:david)),
      params: { push_subscription: shared_browser_subscription }, as: :json
    assert_response :created

    sign_out

    assert_not Push::Subscription.exists?(endpoint: shared_browser_subscription[:endpoint])
  end

  test "another user cannot silently register an existing endpoint" do
    post user_push_subscriptions_path(users(:david)),
      params: { push_subscription: shared_browser_subscription }, as: :json
    assert_response :created

    logout_and_sign_in_as :kevin
    post user_push_subscriptions_path(users(:kevin)),
      params: { push_subscription: shared_browser_subscription }, as: :json

    assert_response :conflict
    assert_equal 1, Push::Subscription.where(endpoint: shared_browser_subscription[:endpoint]).count
  end

  test "a session revoked without logout cannot receive new notifications" do
    post user_push_subscriptions_path(users(:david)),
      params: { push_subscription: shared_browser_subscription }, as: :json
    assert_response :created

    identities(:david).sessions.delete_all
    pool = mock("web push pool")
    pool.expects(:queue).never
    Rails.configuration.x.stubs(:web_push_pool).returns(pool)

    Notification::PushTarget::Web.new(notifications(:logo_mentioned_david)).process
  end

  test "verification preserves only a registration authorized by the current session" do
    post user_push_subscriptions_path(users(:david)), params: { push_subscription: shared_browser_subscription }, as: :json
    subscription = Push::Subscription.find_by!(endpoint: shared_browser_subscription[:endpoint])

    post user_push_subscription_verification_path(users(:david)), params: { push_subscription: shared_browser_subscription }, as: :json
    assert_response :no_content
    assert_equal subscription.id, Push::Subscription.find_by!(endpoint: shared_browser_subscription[:endpoint]).id
  end

  test "changing user retires the old endpoint before a new explicit registration" do
    post user_push_subscriptions_path(users(:david)), params: { push_subscription: shared_browser_subscription }, as: :json
    logout_and_sign_in_as :kevin

    post user_push_subscription_verification_path(users(:kevin)), params: { push_subscription: shared_browser_subscription }, as: :json
    assert_response :conflict
    assert_not Push::Subscription.exists?(endpoint: shared_browser_subscription[:endpoint])

    post user_push_subscriptions_path(users(:kevin)), params: { push_subscription: shared_browser_subscription }, as: :json
    assert_response :created
    assert_equal users(:kevin), Push::Subscription.find_by!(endpoint: shared_browser_subscription[:endpoint]).user
  end

  test "verification with different keys cannot retire another browser" do
    post user_push_subscriptions_path(users(:david)), params: { push_subscription: shared_browser_subscription }, as: :json
    logout_and_sign_in_as :kevin

    post user_push_subscription_verification_path(users(:kevin)),
      params: { push_subscription: shared_browser_subscription.merge(auth_key: "wrong-key") }, as: :json
    assert_response :conflict
    assert Push::Subscription.exists?(endpoint: shared_browser_subscription[:endpoint])
  end

  test "a new session of the same identity must give fresh consent" do
    post user_push_subscriptions_path(users(:david)), params: { push_subscription: shared_browser_subscription }, as: :json
    logout_and_sign_in_as :david

    post user_push_subscription_verification_path(users(:david)), params: { push_subscription: shared_browser_subscription }, as: :json
    assert_response :conflict
    assert_not Push::Subscription.exists?(endpoint: shared_browser_subscription[:endpoint])
  end

  test "logout leaves another device of the same identity subscribed" do
    another_session = identities(:david).sessions.create!
    other = users(:david).push_subscriptions.create!(shared_browser_subscription.merge(session: another_session))
    post user_push_subscriptions_path(users(:david)),
      params: { push_subscription: shared_browser_subscription.merge(endpoint: "https://fcm.googleapis.com/fcm/send/current-device") }, as: :json
    assert_response :created

    sign_out

    assert_equal [ other.id ], users(:david).push_subscriptions.reload.pluck(:id)
  end

  test "queued delivery is authorized only for its original user and session" do
    post user_push_subscriptions_path(users(:david)), params: { push_subscription: shared_browser_subscription }, as: :json
    subscription = Push::Subscription.find_by!(endpoint: shared_browser_subscription[:endpoint])
    token = subscription.signed_id(purpose: :push_delivery)

    get user_push_subscription_verification_path(users(:david), token: token), as: :json
    assert_response :no_content

    logout_and_sign_in_as :kevin
    get user_push_subscription_verification_path(users(:david), token: token), as: :json
    assert_response :forbidden
  end

  test "queued delivery cannot use the registration created after logout" do
    post user_push_subscriptions_path(users(:david)), params: { push_subscription: shared_browser_subscription }, as: :json
    token = Push::Subscription.find_by!(endpoint: shared_browser_subscription[:endpoint]).signed_id(purpose: :push_delivery)
    sign_out
    sign_in_as :david
    post user_push_subscriptions_path(users(:david)), params: { push_subscription: shared_browser_subscription }, as: :json
    assert_response :created

    get user_push_subscription_verification_path(users(:david), token: token), as: :json
    assert_response :forbidden
  end

  test "push payload carries verification for this registration and account" do
    post user_push_subscriptions_path(users(:david)), params: { push_subscription: shared_browser_subscription }, as: :json
    assert_response :created
    subscription = Push::Subscription.find_by!(endpoint: shared_browser_subscription[:endpoint])
    message = nil
    WebPush.expects(:payload_send).with do |**attributes|
      message = JSON.parse(attributes[:message])
      true
    end

    subscription.notification(title: "Private title", body: "Private extract", url: "/card").deliver

    assert_kind_of String, message.dig("options", "data", "verification_url")
    verification_url = URI.parse(message.dig("options", "data", "verification_url"))
    assert_equal "#{subscription.account.slug}/users/#{subscription.user_id}/push_subscription_verification", verification_url.path
    token = Rack::Utils.parse_query(verification_url.query).fetch("token")
    assert_equal subscription, Push::Subscription.find_signed(token, purpose: :push_delivery)
  end

  test "storage rejects the same endpoint for two users" do
    post user_push_subscriptions_path(users(:david)), params: { push_subscription: shared_browser_subscription }, as: :json
    assert_response :created
    assert_raises(ActiveRecord::RecordNotUnique) do
      users(:kevin).push_subscriptions.create!(shared_browser_subscription)
    end
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

    def shared_browser_subscription
      { endpoint: "https://fcm.googleapis.com/fcm/send/shared-browser", p256dh_key: "browser-key", auth_key: "browser-auth" }
    end
end
