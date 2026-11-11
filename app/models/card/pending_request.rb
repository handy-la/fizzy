# Handy: what a person still owes a card, read only from what Fizzy can see.
#
# Dédalo keeps the structured state of a wait (question pending, answered,
# expired) in its own store, not here. What reaches Fizzy is its comments,
# each closed by an invisible MARKER, and the card's stage. This reader walks
# the comments in order and keeps the questions still open:
#
# * A question is a marked comment with ❓ in its text. Questions asked with no
#   answer in between stay open together.
# * A comment by a person answers every open question.
# * A marked comment that opens with ⌛ expires them.
# * A question that names the same Dédalo question id (`q-…-v<n>`) as an
#   earlier one replaces it.
# * Any other marked comment is progress and changes nothing.
# * A marked ⚠️ right after a person's answer (Dédalo refusing it, or asking
#   for the rest of a partial answer) reopens what that answer closed.
#
# It never reads idleness, age or the author alone as a wait. When the
# evidence does not settle the case it answers :review ("Revisar contexto")
# instead of guessing: an unmarked comment from the account that asks, a
# Dédalo warning right after a person's answer, or a card in the
# AWAITING APPROVAL stage with no open question.
class Card::PendingRequest
  MARKER = "​⁠⁣"
  QUESTION = "❓"
  EXPIRED = "⌛"
  WARNING = "\u26A0"
  QUESTION_ID = /`(q-[a-z0-9][a-z0-9-]{0,80})-v\d+`/

  REASONS = {
    requester_unmarked: "Quien pregunta escribió después sin la marca de Dédalo.",
    warning_after_answer: "Dédalo dejó un aviso después de la última respuesta.",
    approval_without_question: "La tarjeta espera en su etapa de aprobación, pero no hay una pregunta abierta."
  }.freeze

  attr_reader :card, :status, :requests, :reason_code

  def self.for(card, comments: nil)
    new(card, comments || card.comments.chronologically.with_rich_text_body.includes(:creator))
  end

  def initialize(card, comments)
    @card = card
    @status, @requests, @reason_code = evaluate(comments.to_a)
  end

  def pending?
    status == :pending
  end

  def review?
    status == :review
  end

  def actionable?
    pending? || review?
  end

  def reason
    REASONS[reason_code]
  end

  # The oldest request still open: what the queue is ordered by.
  def since
    requests.first&.created_at || card.last_active_at
  end

  # Changes when anything a person reads before answering changes: a new
  # comment, another stage, the verdict or the set of open questions.
  def fingerprint
    Digest::SHA256.hexdigest([ status, reason_code, requests.map(&:id), @last_comment_id, card.column_id, card.closed? ].to_json)[0, 16]
  end

  private
    def evaluate(comments)
      @last_comment_id = comments.last&.id

      if card.active?
        walk(comments)
      else
        [ :none, [], nil ]
      end
    end

    def walk(comments)
      open = []
      answered = []
      requester_ids = Set.new
      reason = nil

      comments.each do |comment|
        next if comment.creator&.system?

        text = comment.body.to_plain_text.to_s
        visible = text.delete(MARKER).strip

        if marked?(text)
          if visible.include?(QUESTION)
            open = superseding(open, visible) + [ comment ]
            requester_ids << comment.creator_id
            reason = nil
          elsif visible.start_with?(EXPIRED)
            open = []
            reason = nil
          elsif visible.start_with?(WARNING) && answered.any?
            open = answered
            reason = :warning_after_answer
          end

          answered = []
        elsif open.any? && requester_ids.include?(comment.creator_id)
          reason = :requester_unmarked
        else
          answered = open
          open = []
          reason = nil
        end
      end

      verdict(open, reason, comments)
    end

    def marked?(text)
      text.rstrip.end_with?(MARKER)
    end

    def superseding(open, visible)
      if id = visible[QUESTION_ID, 1]
        open.reject { |earlier| earlier.body.to_plain_text.to_s[QUESTION_ID, 1] == id }
      else
        open
      end
    end

    def verdict(open, reason, comments)
      if open.any?
        [ reason ? :review : :pending, open, reason ]
      elsif card.column&.awaiting_approval?
        [ :review, Array(comments.reverse.find { |comment| marked?(comment.body.to_plain_text.to_s) }), :approval_without_question ]
      else
        [ :none, [], nil ]
      end
    end
end
