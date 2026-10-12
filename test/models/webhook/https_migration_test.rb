require "test_helper"
require Rails.root.join("db/migrate/20261012180000_deactivate_http_webhooks")

class Webhook::HttpsMigrationTest < ActiveSupport::TestCase
  test "deactivates HTTP destinations across accounts and preserves HTTPS and history" do
    secure = webhooks(:active)
    insecure = Webhook.create!(name: "Old HTTP", board: boards(:writebook), url: "https://old.example.com/hook")
    other_account = Webhook.create!(name: "Other account", board: boards(:writebook), url: "https://other.example.com/hook")
    inactive = webhooks(:inactive)
    insecure.update_columns(url: "http://old.example.com/hook")
    other_account.update_columns(url: " HTTP://other.example.com/hook ", account_id: accounts(:initech).id)
    inactive.update_columns(url: "http://inactive.example.com/hook")
    original_url = insecure.url
    original_secret = insecure.signing_secret
    delivery_ids = Webhook::Delivery.ids.sort

    2.times { DeactivateHttpWebhooks.new.up }

    assert_not insecure.reload.active?
    assert_not other_account.reload.active?
    assert_not inactive.reload.active?
    assert secure.reload.active?
    assert_equal original_url, insecure.url
    assert_equal original_secret, insecure.signing_secret
    assert_equal delivery_ids, Webhook::Delivery.ids.sort

    DeactivateHttpWebhooks.new.down
    assert_not insecure.reload.active?
  end
end
