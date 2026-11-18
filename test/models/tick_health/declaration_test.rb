require "test_helper"
require "tempfile"

# Authoring: docs/test-audits/handy-2575.md.
class TickHealth::DeclarationTest < ActiveSupport::TestCase
  include ActionCable::TestHelper
  setup do
    travel_to Time.utc(2026, 11, 18, 23, 1)
    @board = boards(:writebook)
    @registry = Tempfile.new([ "tick-registry", ".json" ])
    @registry.write({ schema: 1, products: [ {
      id: "example", account_id: @board.account.external_account_id.to_s, board_id: @board.id,
      producer_user_id: users(:david).id,
      stages: [ { id: "deploying", column_id: columns(:writebook_review).id, description: "Comprobar despliegues" } ]
    } ] }.to_json)
    @registry.flush
    @previous_registry = ENV["TICK_HEALTH_REGISTRY_FILE"]
    ENV["TICK_HEALTH_REGISTRY_FILE"] = @registry.path
    @body = JSON.parse(file_fixture("tick_health/v1.json").read)
  end

  teardown do
    ENV["TICK_HEALTH_REGISTRY_FILE"] = @previous_registry
    @registry.close!
  end

  test "every operational state retains its distinct semantics and earlier result" do
    %w[ scheduled running waiting_ci waiting_resource deferred lock_busy noop failed no_signal scheduler_missing disabled ].each do |state|
      @body["expected_revision"] = TickHealth.find_by(board: @board)&.revision || 0
      body = @body.merge("state" => state, "expected_event" => "Resultado de comprobación")
      body["next_run_at"] = nil if state.in?(%w[ disabled scheduler_missing ])
      assert_includes [ :created, :updated ], write(body).code
      stage = TickHealth.snapshot(@board)[:stages].sole
      assert_equal state, stage["state"]
      assert_equal "failed", stage["last_result"]
    end
  end

  test "bad times integers waiting evidence and estimates fail before persistence" do
    cases = [
      { "reported_at" => "2026-11-18T23:01:00" },
      { "reported_at" => "2026-11-18T23:01:00+00:60" },
      { "reported_at" => "2026-11-18T23:02:01Z" },
      { "valid_until" => "2026-11-20T23:01:00Z" },
      { "valid_until" => "2026-11-18T23:00:59Z" },
      { "run_sequence" => 2**53 }, { "expected_revision" => -1 }, { "schema" => 1.0 },
      { "phase" => "x" * 201 }, { "last_reason" => "token=secret" },
      { "state" => "waiting_ci", "expected_event" => nil, "next_run_at" => nil },
      { "state" => "scheduler_missing" },
      { "duration_min_seconds" => 20, "duration_max_seconds" => 10, "duration_samples" => 5 },
      { "duration_min_seconds" => 10, "duration_max_seconds" => 20, "duration_samples" => 4 },
      { "last_finished_at" => nil }, { "last_reason" => nil }
    ]
    cases.each do |changes|
      result = write(@body.merge(changes))
      assert_equal :unprocessable_entity, result.status, changes.inspect
    end
    assert_empty TickHealth.where(board: @board)
  end

  test "a report that first arrives expired never gains a fresh deadline" do
    travel 1.hour
    assert_equal :created, write.code
    stage = TickHealth.snapshot(@board)[:stages].sole
    assert_equal "stale", stage["freshness"]
    assert_equal "2026-11-18T23:06:00Z", stage["valid_until"]
  end

  test "newer runs advance only with current revision and retry is idempotent" do
    assert_equal :created, write.code
    next_run = @body.merge("expected_revision" => 1, "run_sequence" => 43, "run_id" => "tick-43")
    assert_equal :updated, write(next_run).code
    assert_equal :replayed, write(next_run).code
    assert_equal 2, TickHealth.where(board: @board).sole.revision
    assert_equal :stale_run, write(@body.merge("expected_revision" => 2)).code
  end

  test "invalid duplicate or reassigned registry mappings expose no automated stage" do
    document = JSON.parse(File.read(@registry.path))
    document["products"] << document["products"].first
    File.write(@registry.path, document.to_json)
    assert_nil TickHealth::Registry.for(@board)
    assert_empty TickHealth.snapshot(@board)[:stages]
    assert_equal :not_configured, write.code
  end

  test "deleting or moving a configured column prevents publication" do
    columns(:writebook_review).update!(board: boards(:private))
    assert_equal :not_configured, write.code
    assert_empty TickHealth.snapshot(@board)[:stages]
  end

  test "only committed changes broadcast and a retry publishes nothing twice" do
    stream = TickHealth.stream_name(@board)
    assert_no_broadcasts stream do
      TickHealth.transaction do
        write
        raise ActiveRecord::Rollback
      end
    end
    assert_empty TickHealth.where(board: @board)
    assert_broadcasts(stream, 1) { write }
    assert_no_broadcasts(stream) { assert_equal :replayed, write.code }
  end

  test "a cable failure does not turn a committed tick report into a failure" do
    ActionCable.server.expects(:broadcast).raises(IOError, "Cable unavailable")
    Rails.error.expects(:report).with(instance_of(IOError), handled: true)
    assert_equal :created, write.code
    assert_equal 1, TickHealth.where(board: @board).sole.revision
  end

  private
    def write(body = @body)
      TickHealth::Declaration.write(board: @board, stage_id: "deploying", body: body, user: users(:david))
    end
end
