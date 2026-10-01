class Webhook::DeliveryJob < ApplicationJob
  queue_as :webhooks

  # Serialize requests to one receiver; pending predecessors enforce card order
  # across scheduled retries. The lease exceeds the bounded HTTP timeout.
  limits_concurrency to: 1, key: ->(delivery) { delivery.webhook_id }, duration: 1.minute

  discard_on ActiveJob::DeserializationError

  def perform(delivery)
    delivery.deliver
  end
end
