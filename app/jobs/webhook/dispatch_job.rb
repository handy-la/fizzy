class Webhook::DispatchJob < ApplicationJob
  queue_as :webhook_dispatch

  def perform(token)
    Webhook::Dispatch.run(token)
  end
end
