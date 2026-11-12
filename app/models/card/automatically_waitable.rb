# Automatic waits declared on the card by an external producer. Closing,
# reopening and moving the card to another board retire every active wait and
# advance the card's fence, so a producer that read the card before the change
# cannot write again with what it read. Contract: docs/automatic-waits.md.
module Card::AutomaticallyWaitable
  extend ActiveSupport::Concern

  included do
    has_many :automatic_waits, class_name: "Card::AutomaticWait", dependent: :delete_all
    has_one :automatic_wait_fence, class_name: "Card::AutomaticWait::Fence", dependent: :delete
  end

  def automatic_wait_summary(now: Time.current)
    Card::AutomaticWait::Summary.new(self, now: now)
  end

  def automatic_wait_epoch
    automatic_wait_fence&.epoch || 0
  end

  private
    def retire_automatic_waits(reason)
      Card::AutomaticWait.transaction do
        fence = Card::AutomaticWait::Fence.lock_for(self)
        fence.advance(reason)
        automatic_waits.active.update_all([ "retired_at = ?, retired_reason = ?, revision = revision + 1, updated_at = ?",
          Time.current, reason, Time.current ])
      end
    end
end
