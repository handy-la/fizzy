require "test_helper"

class Webhook::DispatchTest < ActiveSupport::TestCase
  setup do
    freeze_time
    stub_dns_resolution("93.184.216.34")
    webhook_deliveries(:in_progress).completed!
  end

  test "duplicate jobs cannot release an executing lease or start another request" do
    Webhook::Dispatch.schedule
    token = Webhook::Dispatch.find(Webhook::Dispatch::SINGLETON_ID).token
    seen = 0
    stub_request(:post, webhooks(:active).url).to_return do |_request|
      seen += 1
      Webhook::DispatchJob.perform_now(token)
      dispatch = Webhook::Dispatch.find(Webhook::Dispatch::SINGLETON_ID)
      assert_equal token, dispatch.token
      assert dispatch.running?
      { status: 200 }
    end

    Webhook::DispatchJob.perform_now(token)

    assert_equal 1, seen
    assert webhook_deliveries(:pending).reload.succeeded?
    assert_nil Webhook::Dispatch.find(Webhook::Dispatch::SINGLETON_ID).token
  end

  test "an expired wakeup is replaced and cannot send HTTP" do
    Webhook::Dispatch.schedule
    old_token = Webhook::Dispatch.find(Webhook::Dispatch::SINGLETON_ID).token
    travel 6.minutes
    Webhook::Dispatch.recover
    token = Webhook::Dispatch.find(Webhook::Dispatch::SINGLETON_ID).token
    assert_not_equal old_token, token
    stub_request(:post, webhooks(:active).url).to_return(status: 200)

    Webhook::DispatchJob.perform_now(old_token)
    assert_not_requested :post, webhooks(:active).url
    assert_equal token, Webhook::Dispatch.find(Webhook::Dispatch::SINGLETON_ID).token
    Webhook::DispatchJob.perform_now(token)
    assert webhook_deliveries(:pending).reload.succeeded?
  end

  test "many blocked card successors produce no individual wakeups" do
    delivery = webhook_deliveries(:pending)
    stub_request(:post, delivery.webhook.url).to_return(status: 503)
    delivery.deliver
    20.times do
      travel 1.second
      delivery.webhook.trigger(delivery.event)
    end
    clear_enqueued_jobs
    5.times { Webhook::Dispatch.recover }

    assert_empty enqueued_jobs
    travel 1.minute
    Webhook::Dispatch.recover
    assert_enqueued_jobs 1, only: Webhook::DispatchJob
  end

  test "an interrupted last attempt without a response releases its pending slot" do
    delivery = webhook_deliveries(:pending)
    delivery.update!(state: :in_progress, updated_at: 6.minutes.ago, response: nil,
      request: { attempts: 8, first_attempt_at: 1.hour.ago.iso8601(6) })
    stub_request(:post, delivery.webhook.url).to_return(status: 200)
    Webhook::Dispatch.recover
    perform_enqueued_jobs only: Webhook::DispatchJob

    assert delivery.reload.completed?
    assert_equal "retry_budget_exhausted", delivery.request[:stopped_reason]
    assert delivery.failed?
    assert_not_requested :post, delivery.webhook.url
  end

  test "legacy delivery jobs only wake the pump and never make HTTP requests" do
    stub_request(:post, webhooks(:active).url).to_return(status: 200)
    Webhook::DeliveryJob.perform_now(webhook_deliveries(:pending))
    assert_not_requested :post, webhooks(:active).url
    assert_enqueued_jobs 1, only: Webhook::DispatchJob
  end
end
