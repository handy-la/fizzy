module CommentsHelper
  def new_comment_placeholder(card)
    if card.creator == Current.user && card.comments.empty?
      "Next, add some notes, context, pictures, or video about this…"
    else
      "Type your comment…"
    end
  end

  # Handy #2304: an unsent comment is kept per person and card, so two people
  # on one browser never see each other's draft. The old per-card key is read
  # once and moved by the local-save controller.
  def comment_draft_key(card)
    "comment-#{Current.user.id}-#{card.id}"
  end

  def legacy_comment_draft_key(card)
    "comment-#{card.id}"
  end
end
