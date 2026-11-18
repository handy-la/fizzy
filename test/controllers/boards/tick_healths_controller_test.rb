require "test_helper"
require "tempfile"

# Authoring: docs/test-audits/handy-2575.md.
class Boards::TickHealthsControllerTest < ActionDispatch::IntegrationTest
  setup do
    travel_to Time.utc(2026, 11, 18, 23, 1)
    @board = boards(:writebook)
    @column = columns(:writebook_review)
    @registry = Tempfile.new([ "tick-registry", ".json" ])
    @registry.write({ schema: 1, products: [ {
      id: "example", account_id: @board.account.external_account_id.to_s, board_id: @board.id,
      producer_user_id: users(:david).id,
      stages: [ { id: "deploying", column_id: @column.id, description: "Comprobar despliegues" } ]
    } ] }.to_json)
    @registry.flush
    @previous_registry = ENV["TICK_HEALTH_REGISTRY_FILE"]
    ENV["TICK_HEALTH_REGISTRY_FILE"] = @registry.path
    @auth = { "HTTP_AUTHORIZATION" => "Bearer #{identity_access_tokens(:davids_api_token).token}" }
    @path = "/#{@board.account.external_account_id}/boards/#{@board.id}/tick_health"
    @body = JSON.parse(file_fixture("tick_health/v1.json").read)
  end

  teardown do
    ENV["TICK_HEALTH_REGISTRY_FILE"] = @previous_registry
    @registry.close!
  end

  test "writes reads and repeats the same evidence without advancing revision" do
    write
    assert_response :created
    assert_equal "created", response.parsed_body["result"]
    assert_equal 1, response.parsed_body["stages"].sole["revision"]
    write
    assert_response :ok
    assert_equal "replayed", response.parsed_body["result"]
    get @path, env: @auth
    assert_response :ok
    stage = response.parsed_body["stages"].sole
    assert_equal "tick-42", stage["run_id"]
    assert_equal "failed", stage["last_result"]
    assert_equal "running", stage["state"]
    assert_equal 1, stage["revision"]
  end

  test "unknown properties and invalid fields cannot change the snapshot" do
    cases = {
      "extra" => "ignored", "schema" => 2, "state" => "green", "run_sequence" => "42",
      "reported_at" => "2026-02-30T23:01:00Z", "valid_until" => "tomorrow",
      "phase_started_at" => "2026-11-18T23:01:01Z", "phase" => "Bearer secret",
      "duration_min_seconds" => 10, "last_result" => "green", "product_id" => "other"
    }
    cases.each do |key, value|
      write @body.merge(key => value)
      assert_response :unprocessable_entity, key
    end
    get @path, env: @auth
    assert_equal 0, response.parsed_body["stages"].sole["revision"]
    assert_equal "no_signal", response.parsed_body["stages"].sole["state"]
  end

  test "old revisions runs and reports are rejected independently" do
    write
    write @body.merge("phase" => "Nueva fase")
    assert_response :conflict
    assert_equal "revision_mismatch", response.parsed_body["error"]
    write @body.merge("expected_revision" => 1, "run_sequence" => 41)
    assert_response :conflict
    assert_equal "stale_run", response.parsed_body["error"]
    write @body.merge("expected_revision" => 1, "run_id" => "other")
    assert_response :conflict
    assert_equal "run_conflict", response.parsed_body["error"]
    write @body.merge("expected_revision" => 1, "reported_at" => "2026-11-18T23:00:30Z")
    assert_response :conflict
    assert_equal "stale_report", response.parsed_body["error"]
    write @body.merge("expected_revision" => 1, "state" => "waiting_ci", "expected_event" => "Resultado de CI")
    assert_response :ok
    assert_equal 2, response.parsed_body["stages"].sole["revision"]
  end

  test "expired evidence stays stale and a replay never renews it" do
    write
    travel 10.minutes
    write
    assert_response :ok
    assert_equal "replayed", response.parsed_body["result"]
    assert_equal "stale", response.parsed_body["stages"].sole["freshness"]
  end

  test "unconfigured stages boards other accounts and other writers cannot write" do
    put "#{@path}/human", params: @body.to_json, headers: { "Content-Type" => "application/json" }, env: @auth
    assert_response :not_found
    other_auth = { "HTTP_AUTHORIZATION" => "Bearer #{users(:kevin).identity.access_tokens.create!(description: "Tick test", permission: :write).token}" }
    write @body, auth: other_auth
    assert_response :forbidden
    other_path = @path.sub(@board.id, boards(:private).id)
    get other_path, env: @auth
    assert_response :not_found
    get @path.sub(@board.account.external_account_id.to_s, accounts(:initech).external_account_id.to_s), env: @auth
    assert_response :forbidden
  end

  test "read only identity can read but cannot write" do
    @board.accesses.grant_to(users(:jason))
    readonly = { "HTTP_AUTHORIZATION" => "Bearer #{identity_access_tokens(:jasons_api_token).token}" }
    get @path, env: readonly
    assert_response :ok
    write @body, auth: readonly
    assert_response :unauthorized
  end

  test "body is bounded JSON and nonobject data is rejected" do
    put "#{@path}/deploying", params: @body, env: @auth
    assert_response :unsupported_media_type
    [ [ "[]", :unprocessable_entity ], [ @body.merge("phase" => "x" * 8193).to_json, :payload_too_large ] ].each do |raw, status|
      put "#{@path}/deploying", params: raw, headers: { "Content-Type" => "application/json" }, env: @auth
      assert_response status
    end
  end

  private
    def write(body = @body, auth: @auth)
      put "#{@path}/deploying", params: body.to_json, headers: { "Content-Type" => "application/json" }, env: auth
    end
end
