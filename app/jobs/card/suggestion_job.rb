class Card::SuggestionJob < ApplicationJob
  self.enqueue_after_transaction_commit = true

  queue_as :ai_suggestions
  limits_concurrency to: 1, key: ->(*) { "provider" }, duration: 3.minutes
  discard_on ActiveJob::DeserializationError

  def perform(*_legacy_arguments)
    Card::SuggestionQueue.generate_next
  end
end
