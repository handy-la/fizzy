require "test_helper"

# Authoring answers: docs/test-audits/handy-2306.md.
class Card::AutomaticWait::DeclarationTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:david)
    @card = cards(:logo)
    @user = users(:david)
    travel_to Time.utc(2026, 11, 11, 18, 0, 0)
  end

  test "creates a wait and answers a retry of the same write with the stored row" do
    first = declare(body)
    assert_equal :created, first.status
    assert_equal 1, first.wait.revision

    retry_result = declare(body)
    assert_equal :replayed, retry_result.status
    assert_equal 1, retry_result.wait.reload.revision
    assert_equal 1, @card.automatic_waits.count
  end

  test "a retry is recognised after its dates have passed; a new write with those dates is not" do
    declare(body)

    travel 5.minutes
    assert_equal :replayed, declare(body).status

    travel 1.hour
    assert_equal :replayed, declare(body).status

    late = declare(body(expected_revision: 1, reason: "CI de rails, otra escritura"))
    assert_equal :invalid, late.status
    assert_includes late.details, { attribute: "valid_until", code: "out_of_range" }
    assert_equal 1, wait.revision
  end

  test "the owner clears a pending human decision that closing kept on the card, while it stays closed" do
    declare(body(human_condition: "pending"))
    @card.close
    assert_equal [ "ci:rails-test" ], Card::AutomaticWait::Summary.new(@card.reload).waits.map(&:key)

    other = clear(clear_body(epoch: 1, expected_revision: 2, owner: "otro:producto"))
    assert_equal :owner_mismatch, other.code

    cleared = clear(clear_body(epoch: 1, expected_revision: 2))
    assert_equal :cleared, cleared.status
    assert_empty Card::AutomaticWait::Summary.new(@card.reload).waits
    assert_predicate @card, :closed?

    assert_equal :replayed, clear(clear_body(epoch: 1, expected_revision: 2)).status
    assert_equal :already_retired, clear(clear_body(epoch: 1, expected_revision: 3)).code
  end

  test "a concurrent writer that read the same revision loses the compare-and-swap" do
    declare(body)

    winner = declare(body(expected_revision: 1, reason: "CI en ejecución, segundo paso"))
    loser = declare(body(expected_revision: 1, reason: "CI en ejecución, otra lectura"))

    assert_equal :updated, winner.status
    assert_equal :conflict, loser.status
    assert_equal :revision_mismatch, loser.code
    assert_equal 2, loser.details[:revision]
    assert_equal "CI en ejecución, segundo paso", wait.reason
  end

  test "an out-of-order write based on an old revision is refused" do
    declare(body)
    declare(body(expected_revision: 1, state: "running"))

    late = declare(body(expected_revision: 0, state: "queued", reason: "CI en cola, mensaje atrasado"))

    assert_equal :revision_mismatch, late.code
    assert_equal "running", wait.state
  end

  test "an earlier run is refused and a newer run takes over" do
    declare(body(run_sequence: 5, run_id: "ci-5"))

    assert_equal :stale_run, declare(body(expected_revision: 1, run_sequence: 4, run_id: "ci-4")).code
    assert_equal :run_conflict, declare(body(expected_revision: 1, run_sequence: 5, run_id: "ci-5b")).code

    relay = declare(body(expected_revision: 1, run_sequence: 6, run_id: "ci-6"))
    assert_equal :updated, relay.status
    assert_equal "ci-6", wait.run_id

    assert_equal :stale_run, declare(body(expected_revision: 2, run_sequence: 5, run_id: "ci-5")).code
  end

  test "a cleared wait keeps its protection: the retired run cannot claim it again" do
    declare(body(run_sequence: 3, run_id: "ci-3"))
    assert_equal :cleared, clear(clear_body(expected_revision: 1, run_sequence: 3, run_id: "ci-3")).status
    assert_predicate wait, :retired?

    reclaim = declare(body(expected_revision: 2, run_sequence: 3, run_id: "ci-3"))
    assert_equal :retired_run, reclaim.code

    fresh = declare(body(expected_revision: 2, run_sequence: 4, run_id: "ci-4"))
    assert_equal :updated, fresh.status
    assert_predicate wait, :active?
  end

  test "a clear is idempotent and only the owner can clear" do
    declare(body)

    assert_equal :owner_mismatch, clear(clear_body(owner: "otro:producto")).code
    assert_predicate wait, :active?

    assert_equal :cleared, clear(clear_body).status
    assert_equal :replayed, clear(clear_body).status
    assert_equal 2, wait.revision
  end

  test "the owner hands over only by naming the owner it replaces, with a newer run" do
    declare(body(owner: "dedalo:handy", run_sequence: 2))

    assert_equal :owner_mismatch, declare(body(expected_revision: 1, owner: "dedalo:nuevo", run_sequence: 3)).code
    assert_equal :stale_run, declare(body(expected_revision: 1, owner: "dedalo:nuevo", replaces_owner: "dedalo:handy", run_sequence: 2)).code

    handover = declare(body(expected_revision: 1, owner: "dedalo:nuevo", replaces_owner: "dedalo:handy", run_sequence: 3))
    assert_equal :updated, handover.status

    assert_equal :owner_mismatch, declare(body(expected_revision: 2, owner: "dedalo:handy", run_sequence: 9)).code
    assert_equal :owner_mismatch, clear(clear_body(expected_revision: 2, owner: "dedalo:handy", run_sequence: 9)).code
  end

  test "closing retires every wait, refuses new ones, and the old epoch stays invalid after reopening" do
    declare(body)
    declare(body(key: "monitor:fleet", producer: "monitor", state: "monitoring", run_id: "mon-1"), key: "monitor:fleet")

    @card.close
    assert_equal %w[ closed closed ], @card.automatic_waits.map(&:retired_reason)
    assert_equal :card_closed, declare(body(key: "ci:other"), key: "ci:other").code

    @card.reopen
    assert_equal 2, @card.reload.automatic_wait_epoch

    stale_epoch = declare(body(epoch: 0, expected_revision: 2, run_sequence: 2, run_id: "ci-2"))
    assert_equal :epoch_mismatch, stale_epoch.code
    assert_equal 2, stale_epoch.details[:epoch]

    never_seen = declare(body(epoch: 0), key: "ci:never-seen")
    assert_equal :epoch_mismatch, never_seen.code

    resumed = declare(body(epoch: 2, expected_revision: 2, run_sequence: 2, run_id: "ci-2"))
    assert_equal :updated, resumed.status
  end

  test "moving the card to another board retires its waits" do
    declare(body)

    @card.move_to(boards(:private))

    assert_equal "board_changed", wait.retired_reason
    assert_equal 1, @card.reload.automatic_wait_epoch
    assert_equal :epoch_mismatch, declare(body(expected_revision: 2, run_sequence: 2, run_id: "ci-2")).code
  end

  test "a restarted producer reads the card and continues; what it remembered is refused" do
    declare(body)
    @card.close
    @card.reopen

    remembered = declare(body(expected_revision: 1, run_sequence: 2, run_id: "ci-2"))
    assert_equal :epoch_mismatch, remembered.code

    read = Card::AutomaticWait::Summary.new(@card.reload)
    current = read.rows.find { it.key == "ci:rails-test" }
    continued = declare(body(epoch: @card.automatic_wait_epoch, expected_revision: current.revision, run_sequence: 2, run_id: "ci-2"))
    assert_equal :updated, continued.status
  end

  test "refuses unknown properties, states, producers and missing fields" do
    result = declare(body.merge("command" => "bin/rails test", "producer" => "cron", "state" => "sleeping").except("owner"))

    assert_equal :invalid, result.status
    assert_includes result.details, { attribute: "command", code: "unknown_property" }
    assert_includes result.details, { attribute: "owner", code: "missing" }

    result = declare(body(producer: "cron"))
    assert_includes result.details, { attribute: "producer", code: "unknown_value" }

    result = declare(body(producer: "monitor", state: "running"))
    assert_includes result.details, { attribute: "state", code: "unknown_value" }

    result = declare(body(human_condition: "approved"))
    assert_includes result.details, { attribute: "human_condition", code: "unknown_value" }

    assert_equal :invalid, declare(body, key: "CI rails").status
    assert_equal 0, @card.automatic_waits.count
  end

  test "refuses invalid dates and dates outside the server's horizon" do
    [ [ "valid_until", "mañana", "invalid_date" ],
      [ "valid_until", "2026-11-11 19:00:00", "invalid_date" ],
      [ "valid_until", 1794420000, "invalid_date" ],
      [ "valid_until", "2026-11-11T17:59:00Z", "out_of_range" ],
      [ "valid_until", "2026-11-12T18:00:01Z", "out_of_range" ],
      [ "next_check_at", "2026-11-11T17:58:00Z", "out_of_range" ],
      [ "next_check_at", "2026-11-11T20:00:00Z", "out_of_range" ],
      [ "next_check_at", "2026-02-30T10:00:00Z", "invalid_date" ] ].each do |name, value, code|
      result = declare(body(name.to_sym => value))
      assert_includes result.details, { attribute: name, code: code }, "#{name}=#{value}"
    end

    assert_equal 0, @card.automatic_waits.count
  end

  test "refuses integers sent as strings or out of range" do
    assert_includes declare(body(expected_revision: "0")).details, { attribute: "expected_revision", code: "invalid_integer" }
    assert_includes declare(body(run_sequence: 0)).details, { attribute: "run_sequence", code: "invalid_integer" }
    assert_includes declare(body(epoch: -1)).details, { attribute: "epoch", code: "invalid_integer" }
  end

  test "refuses text shaped like a secret, a token or a command" do
    [ "Bearer abc123", "token=abc", "ghp_0123456789", "https://user:pass@ci.example",
      "bin/rails test; rm -rf", "salida `ls`", "línea\nsiguiente", " con espacio" ].each do |text|
      result = declare(body(reason: text))
      assert_equal :invalid, result.status, text
    end

    assert_equal :invalid, declare(body(expected_event: "x" * 201)).status
    assert_equal :created, declare(body(reason: "CI de rails (rails-test) en ejecución: 3/5 pasos")).status
  end

  test "an event-only wait has no date" do
    result = declare(body(next_check_at: nil, producer: "monitor", state: "monitoring"))

    assert_equal :created, result.status
    assert_nil wait.next_check_at
    assert_equal "event_only", wait.review
  end

  test "limits the active waits per card" do
    Card::AutomaticWait::Declaration::MAX_ACTIVE_PER_CARD.times do |index|
      assert_equal :created, declare(body, key: "ci:job-#{index}").status
    end

    assert_equal :too_many_waits, declare(body, key: "ci:one-more").code
  end

  test "declaring a cleared key again counts against the active limit" do
    declare(body, key: "ci:reused")
    clear(clear_body, key: "ci:reused")
    Card::AutomaticWait::Declaration::MAX_ACTIVE_PER_CARD.times do |index|
      assert_equal :created, declare(body, key: "ci:job-#{index}").status
    end

    reactivated = declare(body(expected_revision: 2, run_sequence: 2, run_id: "ci-2"), key: "ci:reused")

    assert_equal :too_many_waits, reactivated.code
    assert_equal Card::AutomaticWait::Declaration::MAX_ACTIVE_PER_CARD, @card.automatic_waits.active.count
  end

  test "writing never touches the card's activity, column or closure" do
    assert_no_changes -> { @card.reload.slice(:last_active_at, :column_id, :board_id, :status) } do
      declare(body)
      clear(clear_body)
    end
    assert_predicate @card, :open?
  end

  private
    def declare(attributes, key: "ci:rails-test")
      Card::AutomaticWait::Declaration.declare(card: @card.reload, key: key, body: attributes, user: @user)
    end

    def clear(attributes, key: "ci:rails-test")
      Card::AutomaticWait::Declaration.clear(card: @card.reload, key: key, body: attributes, user: @user)
    end

    def wait(key = "ci:rails-test")
      @card.automatic_waits.find_by!(key: key)
    end

    def body(**overrides)
      overrides.delete(:key)
      {
        "epoch" => 0, "expected_revision" => 0,
        "owner" => "dedalo:handy", "run_id" => "ci-1", "run_sequence" => 1,
        "producer" => "ci", "state" => "running",
        "reason" => "CI de rails en ejecución", "expected_event" => "Resultado del job rails-test",
        "next_check_at" => "2026-11-11T18:03:00Z", "valid_until" => "2026-11-11T19:00:00Z",
        "human_condition" => "not_required"
      }.merge(overrides.transform_keys(&:to_s))
    end

    def clear_body(**overrides)
      { "epoch" => 0, "expected_revision" => 1, "owner" => "dedalo:handy", "run_id" => "ci-1", "run_sequence" => 1 }
        .merge(overrides.transform_keys(&:to_s))
    end
end
