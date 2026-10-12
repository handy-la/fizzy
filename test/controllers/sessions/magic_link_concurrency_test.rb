require "test_helper"

class Sessions::MagicLinkConcurrencyTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  test "parallel exchanges of one code create exactly one session" do
    identity = identities(:kevin)
    clients = 2.times.map do
      open_session do |client|
        client.default_url_options = client.default_url_options.merge(script_name: "")
        client.post "/session.json", params: { email_address: identity.email_address }
        assert_equal 201, client.response.status
      end
    end
    magic_link = MagicLink.create!(identity: identity)
    session_count = identity.sessions.count
    ready = Queue.new
    release = Queue.new
    marker = Object.new
    threads = []
    subscriber = ->(event) do
      if Thread.current[:magic_link_exchange] == marker && event.payload[:sql].match?(/\ASELECT .*FROM ["`]magic_links["`]/)
        ready << true
        raise "Timed out waiting to consume the link" unless release.pop(timeout: 10)
      end
    end

    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      threads = clients.map do |client|
        Thread.new do
          Thread.current[:magic_link_exchange] = marker
          ActiveRecord::Base.connection_pool.with_connection do
            client.post "/session/magic_link.json", params: { code: magic_link.code }
          end
        ensure
          Thread.current[:magic_link_exchange] = nil
          Current.reset
        end
      end

      2.times { assert ready.pop(timeout: 10), "Both requests must read the same live link" }
      2.times { release << true }
      threads.each(&:value)
    end

    assert_equal [ 200, 401 ], clients.map { |client| client.response.status }.sort
    assert_equal session_count + 1, Session.uncached { identity.sessions.count }
    assert_not MagicLink.exists?(magic_link.id)
    accepted = clients.find { |client| client.response.status == 200 }
    rejected = clients.find { |client| client.response.status == 401 }
    assert accepted.response.parsed_body["session_token"].present?
    assert_equal "Try another code.", rejected.response.parsed_body["message"]
    assert_nil rejected.response.parsed_body["session_token"]
    assert_not rejected.cookies[:session_token].present?
  ensure
    2.times { release << true } if release
    threads.each(&:join) if threads
  end
end
