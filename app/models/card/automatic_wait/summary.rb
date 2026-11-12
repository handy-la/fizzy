# What a card shows about its automatic waits, computed from the stored rows
# and the server clock. Reading it never writes anything. The order is
# deterministic and keeps every presentable reason: human attention first, then
# active before retired, then the earliest check, then the key.
class Card::AutomaticWait::Summary
  HUMAN_RANK = Card::AutomaticWait::HUMAN_CONDITIONS.each_with_index.to_h.freeze

  attr_reader :card, :now

  def initialize(card, waits: nil, now: Time.current)
    @card, @now = card, now
    @rows = (waits || card.automatic_waits.to_a).sort_by { order_key(it) }
  end

  # Every row of the card, tombstones included, so a producer can verify a write.
  def rows
    @rows
  end

  def waits
    @waits ||= @rows.select(&:presentable?)
  end

  def present?
    waits.any?
  end

  def waiting?
    waits.any?(&:active?)
  end

  # The precedence that the card shows. A person's pending decision or a
  # required intervention wins over everything; then an out-of-date follow-up;
  # "not_required" only when every wait is current and says so explicitly.
  def human
    conditions = waits.map(&:human_condition)

    if conditions.include?("required") then "required"
    elsif conditions.include?("pending") then "pending"
    elsif waits.any? { it.stale?(now) } then "stale"
    elsif conditions.include?("unknown") || conditions.empty? then "unknown"
    else "not_required"
    end
  end

  # The time-independent part of `human`, for the browser to recompute
  # staleness as the clock moves without a new render.
  def declared_human
    conditions = waits.map(&:human_condition)
    %w[ required pending unknown ].find { conditions.include?(it) } || (conditions.any? ? "not_required" : "unknown")
  end

  def no_human_intervention_required?
    human == "not_required"
  end

  def next_check_at
    waits.select { it.active? && it.next_check_at && it.next_check_at > now }.map(&:next_check_at).min
  end

  private
    def order_key(wait)
      [ HUMAN_RANK.fetch(wait.human_condition, HUMAN_RANK.size), wait.active? ? 0 : 1,
        wait.next_check_at ? 0 : 1, wait.next_check_at.to_f, wait.key ]
    end
end
