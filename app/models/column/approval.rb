# Handy: the board stage where a person approves an agent's work. Approving
# cards one after another is a flow of its own, so the card page offers the
# next card still waiting in this stage.
module Column::Approval
  extend ActiveSupport::Concern

  AWAITING_APPROVAL_NAME = "AWAITING APPROVAL"

  def awaiting_approval?
    name.strip.casecmp?(AWAITING_APPROVAL_NAME)
  end

  def next_card_awaiting
    cards.active.latest.with_golden_first.first
  end
end
