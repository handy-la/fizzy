# Compatibility for delivery jobs queued before the global pump was deployed.
class Webhook::DeliveryJob < ApplicationJob
  queue_as :webhooks

  discard_on ActiveJob::DeserializationError

  def perform(delivery)
    delivery.deliver_later
  end
end
