require "test_helper"

class Webhook::DeliveryTest < ActiveSupport::TestCase
  PUBLIC_TEST_IP = "93.184.216.34" # example.com's real IP, used as a public IP stand-in

  setup do
    freeze_time
    stub_dns_resolution(PUBLIC_TEST_IP)
  end

  test "create" do
    webhook = webhooks(:active)
    event = events(:layout_commented)
    delivery = Webhook::Delivery.create!(webhook: webhook, event: event)

    assert_equal "pending", delivery.state
  end

  test "succeeded" do
    webhook = webhooks(:active)
    event = events(:layout_commented)
    delivery = Webhook::Delivery.new(
      webhook: webhook,
      event: event,
      response: { code: 200 },
      state: :completed
    )
    assert delivery.succeeded?

    delivery.response[:code] = 422
    assert_not delivery.succeeded?, "resonse must have a 2XX status"

    delivery.response[:code] = 200
    delivery.state = :pending
    assert_not delivery.succeeded?, "state must be completed"

    delivery.state = :in_progress
    assert_not delivery.succeeded?, "state must be completed"

    delivery.state = :errored
    assert_not delivery.succeeded?, "state must be completed"

    delivery.state = :completed
    delivery.response[:error] = :destination_unreachable

    assert_not delivery.succeeded?, "the response can't have an error"
  end

  test "sanitized_request strips signature header" do
    delivery = webhook_deliveries(:successfully_completed)
    delivery.update!(request: {
      headers: {
        "User-Agent" => "fizzy/1.0.0 Webhook",
        "Content-Type" => "application/json",
        "X-Webhook-Signature" => "super-secret-signature",
        "X-Webhook-Timestamp" => "2025-12-05T19:36:35.401Z"
      }
    })

    result = delivery.sanitized_request
    assert_equal %w[ User-Agent Content-Type X-Webhook-Timestamp ], result[:headers].keys
    assert_not result[:headers].key?("X-Webhook-Signature")
  end

  test "sanitized_request returns nil when request is blank" do
    delivery = webhook_deliveries(:pending)
    delivery.update_columns(request: nil)

    assert_nil delivery.sanitized_request
  end

  test "response_summary returns code and error" do
    delivery = webhook_deliveries(:successfully_completed)
    delivery.update!(response: { code: 200, error: nil })

    result = delivery.response_summary
    assert_equal 200, result[:code]
    assert_nil result[:error]
  end

  test "response_summary returns nil when response is blank" do
    delivery = webhook_deliveries(:pending)
    delivery.update_columns(response: nil)

    assert_nil delivery.response_summary
  end

  test "deliver_later" do
    delivery = webhook_deliveries(:pending)

    assert_enqueued_with job: Webhook::DeliveryJob, args: [ delivery ] do
      delivery.deliver_later
    end
  end

  test "deliver" do
    delivery = webhook_deliveries(:pending)

    stub_request(:post, delivery.webhook.url)
      .to_return(status: 200, headers: { "content-type" => "application/json" })

    assert_equal "pending", delivery.state

    tracker = delivery.webhook.delinquency_tracker
    tracker.update!(consecutive_failures_count: 0)

    assert_no_difference -> { tracker.reload.consecutive_failures_count } do
      delivery.deliver
    end

    assert delivery.persisted?
    assert_equal "completed", delivery.state
    assert delivery.request[:headers].present?
    assert_equal 200, delivery.response[:code]
    assert delivery.response[:error].blank?
    assert delivery.succeeded?
  end

  test "deliver a comment whose body has a content attachment" do
    comment = comments(:layout_overflowing_david)
    comment.update! body: %(<action-text-attachment content-type="text/html" content="&lt;p&gt;Embedded content&lt;/p&gt;"></action-text-attachment>)
    delivery = Webhook::Delivery.create!(webhook: webhooks(:active), event: events(:layout_commented))

    request_stub = stub_request(:post, delivery.webhook.url)
      .with { |request| JSON.parse(request.body).dig("eventable", "body", "html").include?("Embedded content") }
      .to_return(status: 200, headers: { "content-type" => "application/json" })

    delivery.deliver

    assert_requested request_stub
    assert_equal "completed", delivery.state
  end

  test "deliver when the network timeouts" do
    delivery = webhook_deliveries(:pending)
    stub_request(:post, delivery.webhook.url).to_timeout

    tracker = delivery.webhook.delinquency_tracker
    assert_no_difference -> { tracker.reload.consecutive_failures_count } do
      delivery.deliver
    end

    assert_equal "pending", delivery.state
    assert_equal "connection_timeout", delivery.response[:error]
    assert_not delivery.succeeded?
  end

  test "deliver when the connection is refused" do
    delivery = webhook_deliveries(:pending)
    stub_request(:post, delivery.webhook.url).to_raise(Errno::ECONNREFUSED)

    delivery.deliver

    assert_equal "pending", delivery.state
    assert_equal "destination_unreachable", delivery.response[:error]
  end

  test "deliver when an SSL error occurs" do
    delivery = webhook_deliveries(:pending)
    stub_request(:post, delivery.webhook.url).to_raise(OpenSSL::SSL::SSLError)

    delivery.deliver

    assert_equal "pending", delivery.state
    assert_equal "failed_tls", delivery.response[:error]
  end

  test "deliver when an unexpected error occurs" do
    delivery = webhook_deliveries(:pending)
    stub_request(:post, delivery.webhook.url).to_raise(StandardError, "Unexpected error")

    assert_raises(StandardError) do
      delivery.deliver
    end

    assert_equal "errored", delivery.state
  end

  test "deliver with basecamp webhook format" do
    webhook = Webhook.create!(
      board: boards(:writebook),
      name: "Basecamp",
      url: "https://3.basecamp.com/123/integrations/webhook/buckets/456/chats/789/lines"
    )
    event = events(:layout_commented)
    delivery = Webhook::Delivery.create!(webhook: webhook, event: event)

    request_stub = stub_request(:post, webhook.url)
      .with do |request|
        body = CGI.parse(request.body)
        body.key?("content") && body["content"].first.present? &&
        request.headers["Content-Type"] == "application/x-www-form-urlencoded"
      end
      .to_return(status: 200)

    delivery.deliver

    assert_requested request_stub
    assert delivery.succeeded?
  end

  test "deliver with campfire webhook format" do
    webhook = Webhook.create!(
      board: boards(:writebook),
      name: "Campfire",
      url: "https://example.com/rooms/123/456-room-name/messages"
    )
    event = events(:layout_commented)
    delivery = Webhook::Delivery.create!(webhook: webhook, event: event)

    request_stub = stub_request(:post, webhook.url)
      .with do |request|
        request.body.is_a?(String) && !request.body.start_with?("{") && request.body.present? &&
        request.headers["Content-Type"] == "text/html"
      end
      .to_return(status: 200)

    delivery.deliver

    assert_requested request_stub
    assert delivery.succeeded?
  end

  test "deliver with slack webhook format" do
    webhook = Webhook.create!(
      board: boards(:writebook),
      name: "Slack",
      url: "https://hooks.slack.com/services/T12345678/B12345678/abcdefghijklmnopqrstuvwx" # gitleaks:allow
    )
    event = events(:layout_commented)
    delivery = Webhook::Delivery.create!(webhook: webhook, event: event)

    request_stub = stub_request(:post, webhook.url)
      .with do |request|
        body = JSON.parse(request.body)
        body.key?("text") && body["text"].present? &&
        request.headers["Content-Type"] == "application/json"
      end
      .to_return(status: 200)

    delivery.deliver

    assert_requested request_stub
    assert delivery.succeeded?
  end

  test "deliver with generic webhook format" do
    webhook = Webhook.create!(
      board: boards(:writebook),
      name: "Generic",
      url: "https://example.com/webhook"
    )
    event = events(:layout_commented)
    delivery = Webhook::Delivery.create!(webhook: webhook, event: event)

    request_stub = stub_request(:post, webhook.url)
      .with do |request|
        body = JSON.parse(request.body)
        body.present? && !body.key?("line") && !body.key?("text") &&
        request.headers["Content-Type"] == "application/json"
      end
      .to_return(status: 200)

    delivery.deliver

    assert_requested request_stub
    assert delivery.succeeded?
  end

  test "retry 530 and 500 without counting delinquency" do
    [ 530, 500 ].each do |code|
      webhook = Webhook.create!(board: boards(:writebook), name: "Retry", url: "https://example.com/retry")
      delivery = Webhook::Delivery.create!(webhook: webhook, event: events(:shipping_closed))
      stub_request(:post, delivery.webhook.url).to_return(status: code)
      tracker = delivery.webhook.delinquency_tracker
      tracker.update!(consecutive_failures_count: 9, first_failure_at: 2.hours.ago)

      assert_enqueued_with(job: Webhook::DeliveryJob, args: [ delivery ], at: ->(time) { (59.seconds.from_now..61.seconds.from_now).cover?(time) }) do
        delivery.deliver
      end

      assert delivery.reload.pending?
      assert_equal 9, tracker.reload.consecutive_failures_count
      assert delivery.webhook.reload.active?
      delivery.destroy!
    end
  end

  test "4xx is terminal without retry" do
    delivery = webhook_deliveries(:pending)
    stub_request(:post, delivery.webhook.url).to_return(status: 403)

    assert_no_enqueued_jobs only: Webhook::DeliveryJob do
      delivery.deliver
    end

    assert delivery.reload.completed?
    assert_equal 403, delivery.response[:code]
  end

  test "retry succeeds with the same signed bytes and event id" do
    delivery = webhook_deliveries(:pending)
    bodies = []
    signatures = []
    stub_request(:post, delivery.webhook.url).to_return do |request|
      bodies << request.body
      signatures << request.headers["X-Webhook-Signature"]
      { status: bodies.size == 1 ? 530 : 200 }
    end

    delivery.deliver
    events(:shipping_closed).eventable.update_column(:title, "Changed after first attempt")
    travel 1.minute do
      Webhook::DeliveryJob.perform_now(delivery.reload)
    end

    assert delivery.reload.succeeded?
    assert_equal 2, bodies.size
    assert_equal bodies.first, bodies.last
    assert_equal delivery.event_id, JSON.parse(bodies.last)["id"]
    assert_equal signatures.first, signatures.last
    assert_equal 0, delivery.webhook.delinquency_tracker.reload.consecutive_failures_count

    Webhook::DeliveryJob.perform_now(delivery)
    assert_equal 2, bodies.size, "a duplicate job must not resend a terminal delivery"
  end

  test "later delivery on the same card waits but another card proceeds" do
    first = webhook_deliveries(:pending)
    comment_event = Event.create!(eventable: comments(:shipping_1), board: first.event.board,
      creator: first.event.creator, action: "comment_created")
    second = Webhook::Delivery.create!(webhook: first.webhook, event: comment_event)
    other = Webhook::Delivery.create!(webhook: first.webhook, event: events(:logo_published))
    # Historical unfinished fixtures must not block the unrelated card.
    webhook_deliveries(:in_progress).completed!
    seen = []
    stub_request(:post, first.webhook.url).to_return do |request|
      seen << JSON.parse(request.body)["id"]
      { status: seen.size == 1 ? 530 : 200 }
    end

    first.deliver
    second.deliver
    assert_equal [ first.event_id ], seen
    other.deliver
    assert_equal [ first.event_id, other.event_id ], seen
    travel 1.minute do
      first.reload.deliver
      second.reload.deliver
    end
    assert first.reload.succeeded?
    assert second.reload.succeeded?
    assert_equal [ first.event_id, other.event_id, first.event_id, second.event_id ], seen
  end

  test "retry delay increases and is capped at thirty minutes" do
    delivery = webhook_deliveries(:pending)
    stub_request(:post, delivery.webhook.url).to_return(status: 503)

    [ 1, 2, 4, 8, 16, 30, 30 ].each do |minutes|
      assert_enqueued_with(job: Webhook::DeliveryJob, args: [ delivery ], at: minutes.minutes.from_now) do
        delivery.reload.deliver
      end
      travel minutes.minutes
    end
    assert delivery.reload.pending?
  end

  test "retry window expires and counts one terminal failure" do
    delivery = webhook_deliveries(:pending)
    stub_request(:post, delivery.webhook.url).to_timeout
    tracker = delivery.webhook.delinquency_tracker
    delivery.deliver

    travel 24.hours do
      assert_difference -> { tracker.reload.consecutive_failures_count }, 1 do
        assert_no_enqueued_jobs only: Webhook::DeliveryJob do
          delivery.reload.deliver
        end
      end
    end
    assert delivery.reload.completed?
    assert_equal "connection_timeout", delivery.response[:error]
  end

  test "cleanup" do
    webhook = webhooks(:active)
    event = events(:layout_commented)

    fresh_delivery = Webhook::Delivery.create!(webhook: webhook, event: event)
    stale_delivery = Webhook::Delivery.create!(webhook: webhook, event: event, created_at: 8.days.ago)

    Webhook::Delivery.cleanup

    assert Webhook::Delivery.exists?(fresh_delivery.id)
    assert_not Webhook::Delivery.exists?(stale_delivery.id)
  end

  test "renders the creator name when event creator is current user" do
    webhook = Webhook.create!(
      board: boards(:writebook),
      name: "Basecamp",
      url: "https://3.basecamp.com/123/integrations/webhook/buckets/456/chats/789/lines"
    )
    event = events(:logo_published)
    delivery = Webhook::Delivery.create!(webhook: webhook, event: event)

    Current.session = sessions(:david)

    request_stub = stub_request(:post, webhook.url)
      .with { |request| CGI.parse(request.body)["content"].first.include?("David added") }
      .to_return(status: 200)

    delivery.deliver

    assert_requested request_stub
  end

  test "basecamp webhook payload html-escapes special characters" do
    cards(:logo).update_column(:title, %(Tom & Jerry's <Great> "Adventure"))

    webhook = Webhook.create!(
      board: boards(:writebook),
      name: "Basecamp",
      url: "https://3.basecamp.com/123/integrations/webhook/buckets/456/chats/789/lines"
    )
    delivery = Webhook::Delivery.create!(webhook: webhook, event: events(:logo_published))

    captured_body = nil
    stub_request(:post, webhook.url)
      .with { |request| captured_body = request.body; true }
      .to_return(status: 200)

    delivery.deliver

    content = CGI.parse(captured_body)["content"].first

    expected = <<~HTML.strip
      David added &quot;Tom &amp; Jerry&#39;s &lt;Great&gt; &quot;Adventure&quot;&quot;
      <a href="http://example.org/897362094/cards/1">↗︎</a>
    HTML
    assert_equal expected, content
  end

  test "slack webhook payload html-escapes special characters" do
    cards(:logo).update_column(:title, %(Tom & Jerry's <Great> "Adventure"))

    webhook = Webhook.create!(
      board: boards(:writebook),
      name: "Slack",
      url: "https://hooks.slack.com/services/T12345678/B12345678/abcdefghijklmnopqrstuvwx" # gitleaks:allow
    )
    delivery = Webhook::Delivery.create!(webhook: webhook, event: events(:logo_published))

    captured_body = nil
    stub_request(:post, webhook.url)
      .with { |request| captured_body = request.body; true }
      .to_return(status: 200)

    delivery.deliver

    text = JSON.parse(captured_body)["text"]

    expected = <<~TEXT.strip
      David added &quot;Tom &amp; Jerry&#39;s &lt;Great&gt; &quot;Adventure&quot;&quot; <http://example.com/897362094/cards/1|Open in Fizzy>
    TEXT
    assert_equal expected, text
  end

  test "campfire webhook payload html-escapes special characters" do
    cards(:logo).update_column(:title, %(Tom & Jerry's <Great> "Adventure"))

    webhook = Webhook.create!(
      board: boards(:writebook),
      name: "Campfire",
      url: "https://example.com/rooms/123/456-room-name/messages"
    )
    delivery = Webhook::Delivery.create!(webhook: webhook, event: events(:logo_published))

    captured_body = nil
    stub_request(:post, webhook.url)
      .with { |request| captured_body = request.body; true }
      .to_return(status: 200)

    delivery.deliver

    expected = <<~HTML.strip
      David added &quot;Tom &amp; Jerry&#39;s &lt;Great&gt; &quot;Adventure&quot;&quot;
      <a href="http://example.org/897362094/cards/1">↗︎</a>
    HTML
    assert_equal expected, captured_body
  end

  test "generic webhook payload json-encodes special characters" do
    cards(:logo).update_column(:title, %(Tom & Jerry's <Great> "Adventure"))

    webhook = Webhook.create!(
      board: boards(:writebook),
      name: "Generic",
      url: "https://example.com/webhook"
    )
    delivery = Webhook::Delivery.create!(webhook: webhook, event: events(:logo_published))

    captured_body = nil
    stub_request(:post, webhook.url)
      .with { |request| captured_body = request.body; true }
      .to_return(status: 200)

    delivery.deliver

    json = JSON.parse(captured_body)
    assert_equal %(Tom & Jerry's <Great> "Adventure"), json["eventable"]["title"]
  end

  test "renders creator name when event creator is not current user" do
    webhook = Webhook.create!(
      board: boards(:writebook),
      name: "Basecamp",
      url: "https://3.basecamp.com/123/integrations/webhook/buckets/456/chats/789/lines"
    )
    event = events(:logo_published)
    delivery = Webhook::Delivery.create!(webhook: webhook, event: event)

    Current.session = sessions(:kevin)

    request_stub = stub_request(:post, webhook.url)
      .with { |request| CGI.parse(request.body)["content"].first.include?("David added") }
      .to_return(status: 200)

    delivery.deliver

    assert_requested request_stub
  end

  test "blocks DNS rebinding attack where hostname resolves to private IP after validation" do
    webhook = Webhook.create!(
      board: boards(:writebook),
      name: "Rebind Attack",
      url: "https://rebind.attacker.example/webhook"
    )
    event = events(:layout_commented)
    delivery = Webhook::Delivery.create!(webhook: webhook, event: event)

    # Stub DNS to return a private IP (simulating rebind to internal host)
    stub_dns_resolution("169.254.169.254") # AWS IMDS link-local address

    delivery.deliver

    assert_equal "completed", delivery.state
    assert_equal "private_uri", delivery.response[:error]
    assert_not delivery.succeeded?
  end

  test "reports a DNS resolution failure as a lookup failure, not a blocked address" do
    webhook = Webhook.create!(
      board: boards(:writebook),
      name: "Unresolvable",
      url: "https://nxdomain.example.invalid/webhook"
    )
    event = events(:layout_commented)
    delivery = Webhook::Delivery.create!(webhook: webhook, event: event)

    # Host resolves to nothing (timeout/NXDOMAIN), distinct from resolving to a
    # blocked address, which stays private_uri (see the rebinding test above).
    stub_dns_failure

    delivery.deliver

    assert_equal "pending", delivery.state
    assert_equal "dns_lookup_failed", delivery.response[:error]
    assert_not delivery.succeeded?
  end

  test "connects to the pinned IP address preventing DNS re-resolution" do
    webhook = Webhook.create!(
      board: boards(:writebook),
      name: "Pinned IP",
      url: "https://example.com/webhook"
    )
    event = events(:layout_commented)
    delivery = Webhook::Delivery.create!(webhook: webhook, event: event)

    stub_dns_resolution(PUBLIC_TEST_IP)

    # Verify Net::HTTP.new is called with the pinned IP
    response_mock = stub(code: "200")
    response_mock.stubs(:read_body)

    http_mock = mock("http")
    http_mock.stubs(:use_ssl=)
    http_mock.stubs(:ipaddr=)
    http_mock.stubs(:open_timeout=)
    http_mock.stubs(:read_timeout=)
    http_mock.stubs(:request).yields(response_mock).returns(response_mock)

    Net::HTTP.expects(:new).with("example.com", 443).returns(http_mock)

    delivery.deliver

    assert delivery.succeeded?
  end

  test "handles response too large error" do
    delivery = webhook_deliveries(:pending)

    large_body = "x" * 200.kilobytes
    stub_request(:post, delivery.webhook.url).to_return(status: 200, body: large_body)

    delivery.deliver

    assert_equal "completed", delivery.state
    assert_equal "response_too_large", delivery.response[:error]
    assert_not delivery.succeeded?
  end

  test "allows responses within size limit" do
    delivery = webhook_deliveries(:pending)

    small_body = "x" * 50.kilobytes
    stub_request(:post, delivery.webhook.url).to_return(status: 200, body: small_body)

    delivery.deliver

    assert_equal "completed", delivery.state
    assert_equal 200, delivery.response[:code]
    assert delivery.succeeded?
  end
end
