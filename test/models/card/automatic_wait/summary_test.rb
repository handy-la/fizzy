require "test_helper"

# Authoring answers: docs/test-audits/handy-2306.md.
class Card::AutomaticWait::SummaryTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:david)
    @card = cards(:logo)
    travel_to Time.utc(2026, 11, 11, 18, 0, 0)
  end

  test "keeps every reason in a deterministic order: human attention, active, earliest check, key" do
    declare "monitor:b", producer: "monitor", state: "monitoring", next_check_at: nil
    declare "ci:z", next_check_at: "2026-11-11T18:10:00Z"
    declare "ci:a", next_check_at: "2026-11-11T18:10:00Z"
    declare "ci:early", next_check_at: "2026-11-11T18:02:00Z"
    declare "monitor:human", producer: "monitor", state: "monitoring", human_condition: "pending", next_check_at: nil

    assert_equal %w[ monitor:human ci:early ci:a ci:z monitor:b ], summary.waits.map(&:key)
  end

  test "a pending human decision prevails over waits that need no one" do
    declare "ci:rails"
    declare "monitor:deploy", producer: "monitor", state: "monitoring", human_condition: "pending"

    assert_equal "pending", summary.human
    assert_not summary.no_human_intervention_required?
  end

  test "required wins over pending" do
    declare "ci:rails", human_condition: "pending"
    declare "monitor:deploy", producer: "monitor", state: "monitoring", human_condition: "required"

    assert_equal "required", summary.human
  end

  test "no human intervention is required only with explicit current evidence from every wait" do
    declare "ci:rails"
    assert summary.no_human_intervention_required?

    declare "ci:android", human_condition: "unknown"
    assert_equal "unknown", summary.human
    assert_not summary.no_human_intervention_required?
  end

  test "past its validity a wait is an out-of-date follow-up, not an overdue review and not a success" do
    declare "ci:rails", next_check_at: "2026-11-11T18:10:00Z", valid_until: "2026-11-11T18:20:00Z"

    travel 21.minutes
    wait = summary.waits.sole

    assert wait.stale?
    assert_equal "overdue", wait.review
    assert_equal "stale", summary.human
    assert_not summary.no_human_intervention_required?
    assert wait.active?, "staleness never clears or resumes anything"
  end

  test "an overdue review is distinct from validity" do
    declare "ci:rails", next_check_at: "2026-11-11T18:03:00Z", valid_until: "2026-11-11T19:00:00Z"

    travel 2.minutes
    assert_equal "scheduled", summary.waits.sole.review

    travel 2.minutes
    assert_equal "due", summary.waits.sole.review
    assert_equal "not_required", summary.human

    travel 5.minutes
    assert_equal "overdue", summary.waits.sole.review
    assert_not summary.waits.sole.stale?
    assert_equal "not_required", summary.human
  end

  test "an event-only wait has no review date" do
    declare "monitor:fleet", producer: "monitor", state: "monitoring", next_check_at: nil

    assert_equal "event_only", summary.waits.sole.review
    assert_nil summary.next_check_at
  end

  test "closing keeps a pending human decision visible and drops the healthy waits" do
    declare "ci:rails"
    declare "monitor:approval", producer: "monitor", state: "monitoring", human_condition: "pending"

    @card.close
    assert_equal %w[ monitor:approval ], summary.waits.map(&:key)
    assert_not summary.waiting?
    assert_equal "pending", summary.human

    @card.reopen
    assert_equal %w[ monitor:approval ], summary.waits.map(&:key)
    assert_equal "pending", summary.human
  end

  test "an explicit clear by the owner removes the wait from the card but keeps the row" do
    declare "ci:rails"
    Card::AutomaticWait::Declaration.clear(card: @card, key: "ci:rails", user: users(:david),
      body: { "epoch" => 0, "expected_revision" => 1, "owner" => "dedalo:handy", "run_id" => "ci-1", "run_sequence" => 1 })

    assert_not summary.present?
    assert_equal %w[ ci:rails ], summary.rows.map(&:key)
  end

  test "reading never writes" do
    declare "ci:rails"

    assert_no_difference -> { Card::AutomaticWait.maximum(:updated_at).to_f } do
      travel 2.hours
      summary.tap { it.human; it.waits.each(&:review) }
    end
  end

  private
    def summary
      Card::AutomaticWait::Summary.new(@card.reload)
    end

    def declare(key, **overrides)
      wait = @card.automatic_waits.find_by(key: key)
      body = {
        "epoch" => @card.reload.automatic_wait_epoch, "expected_revision" => wait&.revision || 0,
        "owner" => "dedalo:handy", "run_id" => "ci-1", "run_sequence" => 1,
        "producer" => "ci", "state" => "running",
        "reason" => "Motivo #{key}", "expected_event" => "Evento de #{key}",
        "next_check_at" => "2026-11-11T18:03:00Z", "valid_until" => "2026-11-11T19:00:00Z",
        "human_condition" => "not_required"
      }.merge(overrides.transform_keys(&:to_s))
      body.delete("next_check_at") if body["next_check_at"].nil?

      result = Card::AutomaticWait::Declaration.declare(card: @card, key: key, body: body, user: users(:david))
      raise "#{key}: #{result.code} #{result.details}" unless result.success?
      result
    end
end
