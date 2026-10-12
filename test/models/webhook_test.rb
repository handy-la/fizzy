require "test_helper"

class WebhookTest < ActiveSupport::TestCase
  test "create" do
    webhook = Webhook.create! name: "Test", url: "https://example.com/webhook", board: boards(:writebook)
    assert webhook.persisted?
    assert webhook.active?
    assert webhook.signing_secret.present?
    assert webhook.delinquency_tracker.present?
  end

  test "validates the url" do
    webhook = Webhook.new name: "Test", board: boards(:writebook)
    assert_not webhook.valid?
    assert_includes webhook.errors[:url], "not a URL"

    webhook = Webhook.new name: "Test", board: boards(:writebook), url: "not a url"
    assert_not webhook.valid?
    assert_includes webhook.errors[:url], "not a URL"

    webhook = Webhook.new name: "NOTHING", board: boards(:writebook), url: "example.com/webhook"
    assert_not webhook.valid?
    assert_includes webhook.errors[:url], "must use https"

    webhook = Webhook.new name: "BLANK", board: boards(:writebook), url: "//example.com/webhook"
    assert_not webhook.valid?
    assert_includes webhook.errors[:url], "must use https"

    webhook = Webhook.new name: "GOPHER", board: boards(:writebook), url: "gopher://example.com/webhook"
    assert_not webhook.valid?
    assert_includes webhook.errors[:url], "must use https"

    webhook = Webhook.new name: "HTTPS", board: boards(:writebook), url: "https://example.com/webhook"
    assert webhook.valid?

    webhook = Webhook.new name: "TRAILING SPACE", board: boards(:writebook), url: "https://example.com/webhook "
    assert webhook.valid?
    assert_equal "https://example.com/webhook", webhook.url
  end

  test "rejects creating a webhook with HTTP" do
    webhook = Webhook.new name: "HTTP", board: boards(:writebook), url: "http://example.com/webhook"

    assert_not webhook.save
    assert_includes webhook.errors[:url], "must use https"
  end

  test "rejects updating a webhook to HTTP" do
    webhook = webhooks(:active)
    original_url = webhook.url

    assert_not webhook.update(url: "http://example.com/webhook")
    assert_includes webhook.errors[:url], "must use https"
    assert_equal original_url, webhook.reload.url
  end

  test "deactivate" do
    webhook = webhooks(:active)

    assert_changes -> { webhook.active? }, from: true, to: false do
      webhook.deactivate
    end
  end

  test "deactivate a legacy HTTP webhook saves only its state" do
    webhook = webhooks(:active)
    webhook.update_columns(url: "http://example.com/legacy")
    webhook.url = "http://example.com/other"

    travel 1.minute do
      assert_changes -> { Webhook.find(webhook.id).updated_at } do
        webhook.deactivate
      end
    end

    assert_not webhook.reload.active?
    assert_equal "http://example.com/legacy", webhook.url
  end

  test "activate" do
    webhook = webhooks(:inactive)

    assert_changes -> { webhook.active? }, from: false, to: true do
      webhook.activate
    end
  end

  test "for_slack?" do
    webhook = Webhook.new url: "https://hooks.slack.com/services/T12345678/B12345678/abcdefghijklmnopqrstuvwx" # gitleaks:allow
    assert webhook.for_slack?

    webhook = Webhook.new url: "https://hooks.slack.com/services/T12345678/B12345678"
    assert_not webhook.for_slack?

    webhook = Webhook.new url: "https://hooks.slack.com/services/T12345678"
    assert_not webhook.for_slack?

    webhook = Webhook.new url: "https://hooks.slack.com/services/"
    assert_not webhook.for_slack?

    webhook = Webhook.new url: "https://example.com/webhook"
    assert_not webhook.for_slack?
  end

  test "for_campfire?" do
    webhook = Webhook.new url: "https://example.com/rooms/123/456-room-name/messages"
    assert webhook.for_campfire?

    webhook = Webhook.new url: "https://campfire.example.com/rooms/999/123-test-room/messages"
    assert webhook.for_campfire?

    webhook = Webhook.new url: "https://campfire.example.com/rooms/999/123/messages"
    assert_not webhook.for_campfire?, "The bot key is missing a token"

    webhook = Webhook.new url: "https://example.com/webhook"
    assert_not webhook.for_campfire?

    webhook = Webhook.new url: "https://example.com/rooms/123/messages"
    assert_not webhook.for_campfire?

    webhook = Webhook.new url: "https://example.com/rooms/123/456-room-name/"
    assert_not webhook.for_campfire?
  end

  test "for_basecamp?" do
    webhook = Webhook.new url: "https://basecamp.com/999/integrations/some-token/buckets/111/chats/222/lines"
    assert webhook.for_basecamp?

    webhook = Webhook.new url: "https://example.com/webhook"
    assert_not webhook.for_basecamp?

    webhook = Webhook.new url: "https://3.basecamp.com/123/integrations/webhook/buckets/456/chats/"
    assert_not webhook.for_basecamp?

    webhook = Webhook.new url: "https://3.basecamp.com/integrations/webhook/buckets/456/chats/789/lines"
    assert_not webhook.for_basecamp?
  end
end
