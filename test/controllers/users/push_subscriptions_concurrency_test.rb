require "test_helper"

class Users::PushSubscriptionsConcurrencyTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  setup do
    stub_web_push_dns_resolution
    @account = Account.create!(name: "Concurrent push")
    @user = @account.users.create!(name: "Subscriber", identity: identities(:david), role: :owner)
    @authorization = "Bearer #{identity_access_tokens(:davids_api_token).token}"
  end

  teardown do
    @account.destroy!
  end

  test "concurrent registrations admit only five devices" do
    start = Queue.new
    delay_count = ->(event) do
      sleep 0.05 if event.payload[:sql].match?(/SELECT COUNT\(\*\).*push_subscriptions/i)
    end
    statuses = ActiveSupport::Notifications.subscribed(delay_count, "sql.active_record") do
      threads = 6.times.map do |index|
        Thread.new do
          start.pop
          Rails.application.executor.wrap do
            session = ActionDispatch::Integration::Session.new(Rails.application)
            session.post("#{@account.slug}/users/#{@user.id}/push_subscriptions", params: {
              endpoint: "https://fcm.googleapis.com/fcm/send/concurrent-#{index}",
              p256dh_key: "key", auth_key: "auth", client_id: "client-#{index}"
            }, as: :json, headers: { "Authorization" => @authorization })
            session.response.status
          end
        end
      end
      6.times { start << true }
      threads.map(&:value)
    ensure
      threads&.each(&:join)
    end
    assert_equal 5, statuses.count(201), statuses.tally.inspect
    assert_equal 1, statuses.count(429)
    assert_equal 5, @user.push_subscriptions.count
  end
end
