class Card::SuggestionJob < ApplicationJob
  self.enqueue_after_transaction_commit = true

  queue_as :ai_suggestions
  limits_concurrency to: 1, key: ->(*) { "provider" }, duration: 3.minutes
  discard_on ActiveJob::DeserializationError

  def perform(request, token)
    request.generate(token)
  end
end
