# One row per card that has ever had an automatic wait. Its epoch moves when the
# card closes, reopens or changes board, and every write must name the current
# epoch: a producer that read the card before that change is refused, even for a
# key it never declared. The row is never deleted while the card exists.
class Card::AutomaticWait::Fence < ApplicationRecord
  self.table_name = "card_automatic_wait_fences"

  belongs_to :account, default: -> { card.account }
  belongs_to :card, class_name: "::Card"

  def self.for(card)
    create_or_find_by!(card: card)
  end

  # Takes the write lock before anything is read: an UPDATE first, because
  # `with_lock` alone does not take a write lock on SQLite (CLAUDE.md).
  def self.lock_for(card)
    fence = self.for(card)
    where(id: fence.id).update_all(updated_at: Time.current)
    fence.reload
  end

  def advance(reason)
    self.class.where(id: id).update_all([ "epoch = epoch + 1, reason = ?, updated_at = ?", reason, Time.current ])
    reload
  end
end
