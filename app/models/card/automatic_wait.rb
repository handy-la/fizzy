# A wait that an external producer declares on a card: Dédalo's CI queue
# (`ci`, queued or running) or one of its registered monitors (`monitor`).
# Fizzy stores and shows what the producer declares; it never infers a wait from
# comments, age or idle agents, and showing one never changes the card.
#
# A row is keyed by (card, key) and is never deleted by a clear or a retirement:
# the tombstone keeps the owner, the run and the revision, so a retired run can
# never claim it again. Writes go through Card::AutomaticWait::Declaration.
# Contract: docs/automatic-waits.md.
class Card::AutomaticWait < ApplicationRecord
  self.table_name = "card_automatic_waits"

  PRODUCER_STATES = { "ci" => %w[ queued running ], "monitor" => %w[ monitoring ] }.freeze
  HUMAN_CONDITIONS = %w[ required pending unknown not_required ].freeze
  HUMAN_ATTENTION = %w[ required pending ].freeze

  # A retirement by the card, not by the owner. A human condition recorded
  # before it stays visible until the owner declares or clears that key again.
  CARD_RETIREMENTS = %w[ closed reopened board_changed ].freeze
  RETIRED_REASONS = (%w[ cleared ] + CARD_RETIREMENTS).freeze

  # Past its next check, the check is "pending" for this long and "overdue" after.
  OVERDUE_AFTER = 5.minutes

  belongs_to :account, default: -> { card.account }
  belongs_to :card, class_name: "::Card", touch: true
  belongs_to :board
  belongs_to :declared_by, class_name: "User", optional: true

  validates :producer, inclusion: { in: PRODUCER_STATES.keys }
  validates :human_condition, inclusion: { in: HUMAN_CONDITIONS }
  validates :retired_reason, inclusion: { in: RETIRED_REASONS }, allow_nil: true
  validate :state_belongs_to_producer

  scope :active, -> { where(retired_at: nil) }
  scope :retired, -> { where.not(retired_at: nil) }
  scope :presentable, -> {
    active.or(where(retired_reason: CARD_RETIREMENTS, human_condition: HUMAN_ATTENTION))
  }

  def active?
    retired_at.nil?
  end

  def retired?
    !active?
  end

  def cleared?
    retired_reason == "cleared"
  end

  def status
    if active? then "active"
    elsif cleared? then "cleared"
    else "retired"
    end
  end

  def presentable?
    active? || (retired_reason.in?(CARD_RETIREMENTS) && human_attention?)
  end

  def human_attention?
    human_condition.in?(HUMAN_ATTENTION)
  end

  # Validity passed: the follow-up is out of date. It says nothing about the
  # outcome, and only an explicit `required` condition asks for a person.
  def stale?(now = Time.current)
    valid_until <= now
  end

  # "scheduled", "due" (just past), "overdue", or "event_only" with no date.
  # None of them means success, a retry or permission to resume.
  def review(now = Time.current)
    if next_check_at.nil? then "event_only"
    elsif next_check_at > now then "scheduled"
    elsif next_check_at > now - OVERDUE_AFTER then "due"
    else "overdue"
    end
  end

  private
    def state_belongs_to_producer
      unless PRODUCER_STATES.fetch(producer, []).include?(state)
        errors.add(:state, :inclusion)
      end
    end
end
