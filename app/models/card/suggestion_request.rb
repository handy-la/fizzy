class Card::SuggestionRequest < ApplicationRecord
  QUEUE_WAIT = 10.minutes
  GENERATION_WAIT = 2.minutes
  RESULT_RETENTION = 15.minutes

  belongs_to :card
  belongs_to :user

  def self.request(card, user:, kind:, description: nil)
    card.with_lock do
      request = find_or_initialize_by(card: card, user: user, kind: kind)
      request.expire if request.persisted?
      fingerprint = fingerprint_for(card, kind, description)
      if request.new_record? || request.status == "failed" || request.fingerprint != fingerprint
        request.update!(token: SecureRandom.hex(16), fingerprint: fingerprint, status: "pending",
          description: description, suggestion: nil, requested_at: Time.current,
          started_at: nil, finished_at: nil, error_category: nil, expires_at: QUEUE_WAIT.from_now)
        Card::SuggestionJob.perform_later(request, request.token)
      end
      request
    end
  end

  def self.fingerprint_for(card, kind, description = nil)
    context = kind == "title" ? description.to_s : [ card.updated_at, card.comments.maximum(:updated_at) ].map { |time| time&.utc&.iso8601(6) }.join("/")
    Digest::SHA256.hexdigest(context)
  end

  def self.expire_stalled
    where(status: %w[ pending running completed ], expires_at: ..Time.current).find_each(&:expire)
  end

  def generate(token)
    reload
    return unless self.token == token
    expire
    return unless status == "pending"

    if self.class.where(id: id, token: token, status: "pending", expires_at: Time.current..)
        .update_all(status: "running", started_at: Time.current, expires_at: GENERATION_WAIT.from_now, updated_at: Time.current) == 1
      reload
      broadcast_state
      if user.active? && user.accessible_cards.exists?(id: card_id)
        generator = Card::Suggestion.new(card, user: user)
        result = kind == "title" ? generator.title(description) : generator.comment
        if kind == "comment" && fingerprint != self.class.fingerprint_for(card.reload, kind)
          finish(token, "failed", error_category: "superseded")
        else
          finish(token, "completed", result)
        end
      else
        finish(token, "failed", error_category: "access_revoked")
      end
    end
  rescue Card::Suggestion::ContextTooLarge
    finish(token, "failed", error_category: "context_too_large")
  rescue Card::Suggestion::EmptyResponse
    finish(token, "failed", error_category: "empty")
  rescue Card::Suggestion::IncompleteResponse
    finish(token, "failed", error_category: "incomplete")
  rescue Faraday::TimeoutError
    finish(token, "failed", error_category: "timeout")
  rescue RubyLLM::Error, RubyLLM::ConfigurationError, Faraday::Error => error
    category = error.cause.is_a?(Faraday::TimeoutError) || error.cause.is_a?(Timeout::Error) ? "timeout" : "provider"
    finish(token, "failed", error_category: category)
  rescue StandardError
    # Do not persist exception messages: providers can include private content.
    finish(token, "failed", error_category: "interrupted")
    raise
  end

  def expire
    if expires_at <= Time.current
      category = { "pending" => "queue_expired", "running" => "interrupted", "completed" => "result_expired" }[status]
      finish(token, "failed", error_category: category, expired: true) if category
    end
    reload
  end

  def state
    expire
    if status == "completed" && kind == "comment" && fingerprint != self.class.fingerprint_for(card.reload, kind)
      finish(token, "failed", error_category: "superseded")
      reload
    end
    { request_id: token, status: status, suggestion: status == "completed" ? suggestion : nil,
      error_category: error_category, expires_at: expires_at.iso8601(3) }
  end

  def stream_name
    "card-suggestion:#{user.account_id}:#{user_id}:#{id}:#{token}"
  end

  private
    def finish(token, status, suggestion = nil, error_category: nil, expired: false)
      scope = self.class.where(id: id, token: token, status: %w[ pending running completed ])
      scope = scope.where(expires_at: ..Time.current) if expired
      if scope
          .update_all(status: status, suggestion: suggestion, description: nil, error_category: error_category,
            finished_at: Time.current, expires_at: RESULT_RETENTION.from_now, updated_at: Time.current) == 1
        reload
        log_outcome
        broadcast_state
      end
    end

    def log_outcome
      Rails.logger.info({ event: "ai_suggestion_finished", kind: kind, status: status, error_category: error_category,
        queue_ms: started_at && requested_at ? ((started_at - requested_at) * 1000).round : nil,
        generation_ms: started_at ? ((finished_at - started_at) * 1000).round : nil }.to_json)
    end

    def broadcast_state
      # Notification only. The channel rechecks current access before sending text.
      ActionCable.server.broadcast(stream_name, { request_id: token })
    end
end
