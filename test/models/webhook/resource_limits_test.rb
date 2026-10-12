require "test_helper"

class Webhook::ResourceLimitsTest < ActiveSupport::TestCase
  setup do
    freeze_time
    webhook_deliveries(:in_progress).completed!
    stub_dns_resolution("93.184.216.34")
  end

  test "board quota includes inactive webhooks and rejects without rows or jobs" do
    board = boards(:writebook)
    (5 - board.webhooks.count).times { create_webhook(board, active: false) }
    assert_no_difference [ "Webhook.count", "Webhook::DelinquencyTracker.count" ] do
      assert_no_enqueued_jobs do
        webhook = board.webhooks.build(name: "Overflow", url: "https://example.com/overflow")
        assert_not webhook.save
        assert webhook.errors[:base].present?
      end
    end
  end

  test "account quota covers multiple boards" do
    account = accounts(:"37s")
    while account.webhooks.count < 20
      board = account.boards.create!(name: "Quota board", creator: users(:kevin))
      [ 5, 20 - account.webhooks.count ].min.times { create_webhook(board) }
    end
    board = account.boards.create!(name: "Overflow board", creator: users(:kevin))
    assert_no_difference "Webhook.count" do
      assert_not board.webhooks.build(name: "Overflow", url: "https://example.com/overflow").save
    end
  end

  test "pending quota is shared across webhooks and rejected triggers add no job" do
    webhook = webhooks(:active)
    (100 - Webhook::Delivery.where(account: webhook.account, state: %w[ pending in_progress ]).count).times do
      webhook.trigger(events(:shipping_closed))
    end
    other = create_webhook(boards(:private))
    assert_no_difference "Webhook::Delivery.count" do
      assert_no_enqueued_jobs { other.trigger(events(:layout_published)) }
    end
    webhook_deliveries(:pending).completed!
    assert_difference "Webhook::Delivery.count", 1 do
      other.trigger(events(:layout_published))
    end
  end

  test "many delivery wakeups create only one scheduler job" do
    clear_enqueued_jobs
    20.times { webhooks(:active).trigger(events(:shipping_closed)) }
    assert_equal 1, enqueued_jobs.size
    20.times { webhook_deliveries(:pending).deliver_later }
    assert_equal 1, enqueued_jobs.size
  end

  test "a failing delivery stops after eight attempts" do
    delivery = webhook_deliveries(:pending)
    request = stub_request(:post, delivery.webhook.url).to_return(status: 503)
    8.times do
      delivery.reload.deliver
      travel 30.minutes
    end
    assert delivery.reload.completed?
    assert_requested request, times: 8
    delivery.deliver
    assert_requested request, times: 8
  end

  test "a busy account cannot take two turns before another ready account" do
    Webhook::Delivery.pending.delete_all
    first_webhook = webhooks(:active)
    other_event = Event.create!(eventable: cards(:radio), board: boards(:miltons_wish_list),
      creator: users(:mike), action: "card_closed")
    other_webhook = create_webhook(boards(:miltons_wish_list))
    other_webhook.update_column(:url, "https://example.com/other")
    seen = []
    [ first_webhook, other_webhook ].each do |webhook|
      stub_request(:post, webhook.url).to_return do |_request|
        seen << Current.account.id
        { status: 200 }
      end
    end
    clear_enqueued_jobs
    3.times do
      first_webhook.trigger(events(:shipping_closed))
      travel 1.second
    end
    Current.with_account(other_webhook.account) { other_webhook.trigger(other_event) }

    4.times { perform_enqueued_jobs only: ->(payload) { payload.fetch(:job).name.start_with?("Webhook::") } }

    assert_equal [ first_webhook.account_id, other_webhook.account_id ].sort, seen.first(2).sort
    assert_equal 4, seen.size
    assert_equal 0, Webhook::Delivery.pending.count
  end

  test "account retry budget stops the sixty first retry across deliveries" do
    webhook = create_webhook(boards(:private))
    stub_request(:post, webhook.url).to_timeout
    deliveries = 61.times.map do |index|
      card = webhook.board.cards.create!(title: "Retry #{index}", creator: users(:kevin), status: :drafted)
      event = Event.create!(eventable: card, board: webhook.board, creator: users(:kevin), action: "card_published")
      delivery = webhook.deliveries.create!(event: event)
      delivery.deliver
      assert delivery.reload.pending?
      delivery
    end
    clear_enqueued_jobs
    stub_request(:post, webhook.url).to_return(status: 200)
    travel 1.minute
    deliveries.each { |delivery| delivery.reload.deliver }

    assert_equal 60, deliveries.count { |delivery| delivery.reload.succeeded? }
    assert deliveries.last.completed?
    assert_equal "retry_budget_exhausted", deliveries.last.request[:stopped_reason]
    assert_equal "connection_timeout", deliveries.last.response[:error]
    assert_requested :post, webhook.url, times: 121
  end

  test "an active request blocks all receivers of its account" do
    first = webhook_deliveries(:pending)
    first.update!(state: :in_progress)
    other = create_webhook(boards(:private)).deliveries.create!(event: events(:layout_published))
    stub_request(:post, other.webhook.url).to_return(status: 200)

    other.deliver

    assert other.reload.pending?
    assert_not_requested :post, other.webhook.url
  end

  test "default and incineration work for another account with a saturated webhook backlog" do
    webhook = webhooks(:active)
    (100 - Webhook::Delivery.where(account: webhook.account, state: %w[ pending in_progress ]).count).times do
      webhook.trigger(events(:shipping_closed))
    end
    account = accounts(:initech)
    tag = Tag.create!(account: account, title: "Unused during saturation")
    account.create_cancellation!(initiated_by: users(:mike), created_at: 31.days.ago)
    Current.with_account(account) do
      DeleteUnusedTagsJob.perform_later
      Account::IncinerateDueJob.perform_later
    end
    stub_request(:post, webhook.url).to_timeout

    perform_enqueued_jobs queue: "default"
    assert_not Tag.exists?(tag.id)
    perform_enqueued_jobs queue: "incineration"
    assert_not Account.exists?(account.id)
    assert_equal 100, Webhook::Delivery.pending.where(account: webhook.account).count
    assert_not_requested :post, webhook.url
  end

  test "normal workers cannot consume webhook queues" do
    config = YAML.safe_load(ERB.new(File.read(Rails.root.join("config/queue.yml"))).result, aliases: true).fetch("production")
    normal = config.fetch("workers").select { |worker| worker.fetch("queues").include?("default") }
    assert normal.any?
    normal.each do |worker|
      assert_empty worker.fetch("queues") & %w[ webhooks webhook_dispatch ]
      assert_includes worker.fetch("queues"), "incineration"
      assert_not_includes worker.fetch("queues"), "*"
    end
    assert config.fetch("workers").any? { |worker| worker.fetch("queues") == [ "webhook_dispatch" ] }
  end

  private
    def create_webhook(board, **attributes)
      Webhook.create!(board: board, name: "Quota", url: "https://example.com/hook", **attributes)
    end
end
