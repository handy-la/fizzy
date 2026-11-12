require "test_helper"

# Authoring answers: docs/test-audits/handy-2306.md.
class Cards::AutomaticWaitsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @card = cards(:logo)
    @write = { "HTTP_AUTHORIZATION" => "Bearer #{identity_access_tokens(:davids_api_token).token}" }
    @read_only = { "HTTP_AUTHORIZATION" => "Bearer #{identity_access_tokens(:jasons_api_token).token}" }
    travel_to Time.utc(2026, 11, 11, 18, 0, 0)
  end

  test "declares, reads back and clears with a write token" do
    put card_automatic_wait_path(@card, "ci:rails-test"), params: body.to_json, headers: json_headers, env: @write

    assert_response :created
    assert_equal "created", response.parsed_body["result"]
    assert_equal({ "number" => 1, "board_id" => @card.board_id, "closed" => false }, response.parsed_body["card"])
    assert_equal 0, response.parsed_body["epoch"]
    assert_equal true, response.parsed_body.dig("summary", "no_human_intervention_required")

    get card_automatic_waits_path(@card), env: @write
    assert_response :ok
    wait = response.parsed_body["waits"].sole
    assert_equal({
      "key" => "ci:rails-test", "status" => "active", "retired_reason" => nil, "retired_at" => nil, "presented" => true,
      "producer" => "ci", "state" => "running", "owner" => "dedalo:handy", "run_id" => "ci-1", "run_sequence" => 1,
      "reason" => "CI de rails en ejecución", "expected_event" => "Resultado del job rails-test",
      "human_condition" => "not_required", "epoch" => 0, "revision" => 1,
      "next_check_at" => "2026-11-11T18:03:00.000000Z", "valid_until" => "2026-11-11T19:00:00.000000Z",
      "review" => "scheduled", "freshness" => "current", "updated_at" => "2026-11-11T18:00:00.000000Z"
    }, wait)

    delete card_automatic_wait_path(@card, "ci:rails-test"), headers: json_headers, env: @write,
      params: { epoch: 0, expected_revision: 1, owner: "dedalo:handy", run_id: "ci-1", run_sequence: 1 }.to_json
    assert_response :ok
    assert_equal "cleared", response.parsed_body["waits"].sole["status"]
    assert_equal [], response.parsed_body.dig("summary", "presented_keys")
  end

  test "a retry of the same write answers 200 with the stored row" do
    2.times { put card_automatic_wait_path(@card, "ci:rails-test"), params: body.to_json, headers: json_headers, env: @write }

    assert_response :ok
    assert_equal "replayed", response.parsed_body["result"]
    assert_equal 1, @card.automatic_waits.sole.revision
  end

  test "conflicts answer 409 with the current revision and epoch" do
    put card_automatic_wait_path(@card, "ci:rails-test"), params: body.to_json, headers: json_headers, env: @write
    put card_automatic_wait_path(@card, "ci:rails-test"), params: body("reason" => "Otro motivo").to_json, headers: json_headers, env: @write

    assert_response :conflict
    assert_equal({ "error" => "revision_mismatch", "details" => { "revision" => 1, "epoch" => 0 } }, response.parsed_body)
  end

  test "a read-only token reads but cannot write" do
    boards(:writebook).accesses.grant_to(users(:jason))

    get card_automatic_waits_path(@card), env: @read_only
    assert_response :ok

    put card_automatic_wait_path(@card, "ci:rails-test"), params: body.to_json, headers: json_headers, env: @read_only
    assert_response :unauthorized
    assert_equal 0, Card::AutomaticWait.count
  end

  test "a card on a board the user cannot access is not found" do
    Current.session = sessions(:kevin)
    private_card = boards(:private).cards.create!(title: "Privada", creator: users(:kevin), status: :published)
    Current.reset

    get card_automatic_waits_path(private_card), env: @write
    assert_response :not_found

    put card_automatic_wait_path(private_card, "ci:rails-test"), params: body.to_json, headers: json_headers, env: @write
    assert_response :not_found
    assert_equal 0, Card::AutomaticWait.count
  end

  test "a card number resolves inside the request's account, and another account refuses the identity" do
    initech_card = cards(:radio)

    put card_automatic_wait_path(initech_card, "ci:rails-test"), params: body.to_json, headers: json_headers, env: @write
    assert_response :created
    assert_equal [ @card ], Card::AutomaticWait.all.map(&:card), "the number resolves inside this account only"

    put card_automatic_wait_path(initech_card, "ci:rails-test", script_name: "/#{accounts(:initech).external_account_id}"),
      params: body.to_json, headers: json_headers, env: @write
    assert_response :forbidden
    assert_equal 0, initech_card.automatic_waits.count
  end

  test "another user's draft is not found" do
    Current.session = sessions(:kevin)
    draft = boards(:writebook).cards.create!(title: "Borrador", creator: users(:kevin), status: :drafted)
    Current.reset

    put card_automatic_wait_path(draft, "ci:rails-test"), params: body.to_json, headers: json_headers, env: @write
    assert_response :not_found
  end

  test "an unknown property is refused first; then every invalid value answers 422" do
    put card_automatic_wait_path(@card, "ci:rails-test"), headers: json_headers, env: @write,
      params: body("command" => "bin/ci", "state" => "sleeping", "valid_until" => "mañana").to_json

    assert_response :unprocessable_entity
    assert_equal "invalid", response.parsed_body["error"]
    assert_equal [
      { "attribute" => "command", "code" => "unknown_property" }
    ], response.parsed_body["details"]

    put card_automatic_wait_path(@card, "ci:rails-test"), headers: json_headers, env: @write,
      params: body("state" => "sleeping", "valid_until" => "mañana").to_json
    assert_response :unprocessable_entity
    assert_includes response.parsed_body["details"], { "attribute" => "state", "code" => "unknown_value" }
    assert_includes response.parsed_body["details"], { "attribute" => "valid_until", "code" => "invalid_date" }
  end

  test "the body must be JSON and bounded" do
    put card_automatic_wait_path(@card, "ci:rails-test"), params: body, env: @write
    assert_response :unsupported_media_type

    put card_automatic_wait_path(@card, "ci:rails-test"), params: body("reason" => "x" * 9.kilobytes).to_json, headers: json_headers, env: @write
    assert_response :payload_too_large

    put card_automatic_wait_path(@card, "ci:rails-test"), params: "[]", headers: json_headers, env: @write
    assert_response :unprocessable_entity
    assert_equal [ { "attribute" => "body", "code" => "not_an_object" } ], response.parsed_body["details"]
  end

  test "a closed card refuses new waits" do
    @card.close(user: users(:david))

    put card_automatic_wait_path(@card, "ci:rails-test"), params: body("epoch" => 1).to_json, headers: json_headers, env: @write

    assert_response :conflict
    assert_equal "card_closed", response.parsed_body["error"]
  end

  # Handy #2314 — authoring answers: docs/test-audits/handy-2314.md.
  test "expired evidence is published as stale with its original date" do
    put card_automatic_wait_path(@card, "monitor:fleet"), headers: json_headers, env: @write,
      params: body("producer" => "monitor", "state" => "monitoring", "next_check_at" => "2026-11-11T17:20:00Z",
        "valid_until" => "2026-11-11T17:30:00Z", "human_condition" => "pending").to_json

    assert_response :created
    assert_equal "pending", response.parsed_body.dig("summary", "human")
    wait = response.parsed_body["waits"].sole
    assert_equal [ "2026-11-11T17:30:00.000000Z", "stale", "overdue" ], wait.values_at("valid_until", "freshness", "review")
  end

  # Handy #2337 — authoring answers: docs/test-audits/handy-2337.md.
  test "a late first write keeps its overdue review and current evidence" do
    put card_automatic_wait_path(@card, "monitor:fleet"), headers: json_headers, env: @write,
      params: body("producer" => "monitor", "state" => "monitoring", "next_check_at" => "2026-11-11T17:50:00Z",
        "valid_until" => "2026-11-11T18:05:00Z", "human_condition" => "pending").to_json

    assert_response :created
    assert_equal "pending", response.parsed_body.dig("summary", "human")
    assert_nil response.parsed_body.dig("summary", "next_check_at")
    wait = response.parsed_body["waits"].sole
    assert_equal [ "2026-11-11T17:50:00.000000Z", "2026-11-11T18:05:00.000000Z", "current", "overdue" ],
      wait.values_at("next_check_at", "valid_until", "freshness", "review")
  end

  test "clearing a key that was never declared is not found" do
    delete card_automatic_wait_path(@card, "ci:nunca"), headers: json_headers, env: @write,
      params: { epoch: 0, expected_revision: 1, owner: "dedalo:handy", run_id: "ci-1", run_sequence: 1 }.to_json

    assert_response :not_found
    assert_equal "wait_not_found", response.parsed_body["error"]
  end

  private
    def json_headers
      { "Content-Type" => "application/json", "Accept" => "application/json" }
    end

    def body(overrides = {})
      {
        "epoch" => 0, "expected_revision" => 0,
        "owner" => "dedalo:handy", "run_id" => "ci-1", "run_sequence" => 1,
        "producer" => "ci", "state" => "running",
        "reason" => "CI de rails en ejecución", "expected_event" => "Resultado del job rails-test",
        "next_check_at" => "2026-11-11T18:03:00Z", "valid_until" => "2026-11-11T19:00:00Z",
        "human_condition" => "not_required"
      }.merge(overrides)
    end
end
