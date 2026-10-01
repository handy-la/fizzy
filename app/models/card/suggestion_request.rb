class Card::SuggestionRequest < ApplicationRecord
  belongs_to :card
  belongs_to :user

  def self.request(card, user:, kind:, description: nil)
    context = kind == "title" ? description : [ card.updated_at, card.comments.maximum(:updated_at) ].join("/")
    fingerprint = Digest::SHA256.hexdigest(context)
    card.with_lock do
      request = find_or_initialize_by(card: card, user: user, kind: kind)
      if request.new_record? || request.expires_at <= Time.current || (request.fingerprint != fingerprint && (kind == "title" || request.status != "pending"))
        request.update!(token: SecureRandom.hex(16), fingerprint: fingerprint, status: "pending",
          description: description, suggestion: nil, expires_at: 5.minutes.from_now)
        Card::SuggestionJob.perform_later(request, request.token)
      end
      request
    end
  end

  def generate(token)
    return unless self.token == token && status == "pending" && expires_at > Time.current

    if user.active? && user.accessible_cards.exists?(id: card_id)
      generator = Card::Suggestion.new(card, user: user)
      result = kind == "title" ? generator.title(description) : generator.comment
      finish(token, "completed", result)
    else
      finish(token, "failed")
    end
  rescue Card::Suggestion::ContextTooLarge, RubyLLM::Error, RubyLLM::ConfigurationError, Faraday::Error
    # Do not persist or log provider errors, which can contain private content.
    finish(token, "failed")
  end

  private
    def finish(token, status, suggestion = nil)
      self.class.where(id: id, token: token).update_all(status: status, suggestion: suggestion, description: nil, updated_at: Time.current)
    end
end
