require "test_helper"

# Authoring answers: docs/test-audits/handy-2348.md.
class WorkMapsControllerTest < ActionDispatch::IntegrationTest
  include WorkMapTestHelper

  setup do
    @secret = with_current_user(:kevin) do
      boards(:private).cards.create!(title: "Plan secreto de Kevin", creator: users(:kevin), status: "published")
    end
  end

  teardown do
    ENV.delete("WORK_MAP_SOURCE_FILE")
  end

  test "the page carries every accessible product in one graph, and nothing of another board" do
    serve work_map_answer(
      products: [ work_map_product("alpha", boards(:writebook), name: "Alpha"), work_map_product("beta", boards(:private), name: "Beta oculto") ],
      items: [ work_map_item("beta", @secret, wait: work_map_wait(reason: "Razón privada de Beta")) ],
      relations: [ work_map_relation([ "beta", @secret ], [ "alpha", cards(:text) ]) ])
    sign_in_as :david

    get work_map_path

    assert_response :success
    payload = page_payload
    assert_equal [ "Alpha" ], payload["products"].map { |product| product["name"] }
    assert_not_includes response.body, "Plan secreto de Kevin"
    assert_not_includes response.body, "Beta oculto"
    assert_not_includes response.body, "Razón privada de Beta"
    assert_not_includes response.body, "card-#{@secret.number}"

    hidden = payload["nodes"].find { |node| node["kind"] == "inaccessible" }
    assert_equal({ "id" => hidden["id"], "kind" => "inaccessible", "product" => nil, "number" => nil }, hidden)
    assert_equal [ hidden["id"], "card-#{cards(:text).number}" ], payload["edges"].sole.values_at("from", "to")
  end

  test "the owner of both boards sees the cross-product relation and the wait" do
    serve work_map_answer(
      products: [ work_map_product("alpha", boards(:writebook)), work_map_product("beta", boards(:private)) ],
      items: [ work_map_item("beta", @secret, state: "held", wait: work_map_wait(kind: "human", human: "required", reason: "Falta tu decisión")) ],
      relations: [ work_map_relation([ "beta", @secret ], [ "alpha", cards(:text) ], condition: "publication") ])
    sign_in_as :kevin

    get work_map_path

    payload = page_payload
    secret = payload["nodes"].find { |node| node["number"] == @secret.number }
    assert_equal "beta", secret["product"]
    assert_equal "/#{accounts("37s").external_account_id}/cards/#{@secret.number}", secret["url"]
    assert_equal "Falta tu decisión", secret.dig("execution", "wait", "reason")
    assert_equal [ "card-#{@secret.number}", "card-#{cards(:text).number}", "publication" ], payload["edges"].sole.values_at("from", "to", "condition")
  end

  test "the browser gets only allowed fields, and free text cannot close the script" do
    serve work_map_answer(
      products: [ work_map_product("alpha", boards(:writebook)) ],
      items: [ work_map_item("alpha", cards(:text), wait: work_map_wait(reason: "</script><script>alert(1)</script>")) ])
    sign_in_as :david

    get work_map_path

    assert_not_includes response.body, "<script>alert(1)"
    payload = page_payload
    assert_equal %w[ edges generated_at max_cards nodes products source truncated ], payload.keys.sort
    card = payload["nodes"].find { |node| node["number"] == cards(:text).number }
    assert_equal %w[ closed_at disposition execution execution_status id kind number product stage title url ], card.keys.sort
    assert_equal %w[ milestones state wait ], card["execution"].keys.sort
    assert_equal "</script><script>alert(1)</script>", card.dig("execution", "wait", "reason")
    assert_equal %w[ error key name read_at status truncated ], payload["products"].first.keys.sort
  end

  # Handy #2412: a postponed card reaches the page only as a reference with no title.
  test "a postponed card reaches the page only as a postponed reference" do
    with_current_user(:kevin) { cards(:logo).postpone }
    serve work_map_answer(products: [ work_map_product("alpha", boards(:writebook)) ],
      relations: [ work_map_relation([ "alpha", cards(:logo) ], [ "alpha", cards(:text) ]) ])
    sign_in_as :david

    get work_map_path

    payload = page_payload
    assert_not_includes response.body, cards(:logo).title.to_json[1..-2]
    assert_not payload["nodes"].any? { |node| node["kind"] == "card" && node["number"] == cards(:logo).number }
    postponed = payload["nodes"].find { |node| node["kind"] == "postponed" }
    assert_equal({ "id" => postponed["id"], "kind" => "postponed", "product" => "alpha", "number" => cards(:logo).number }, postponed)
    assert_equal [ postponed["id"], "card-#{cards(:text).number}" ], payload["edges"].sole.values_at("from", "to")
  end

  test "a failed source is shown as failed, with every card still there" do
    serve "not json"
    sign_in_as :david

    get work_map_path

    payload = page_payload
    assert_equal [ "failed", "invalid_json" ], payload["source"].values_at("status", "error")
    assert_equal [ "source_failed" ], payload["products"].map { |product| product["status"] }.uniq
    assert_includes payload["nodes"].map { |node| node["number"] }, cards(:text).number
  end

  test "the menu links to the work map" do
    sign_in_as :david

    get my_menu_path

    assert_select "a[href=?]", work_map_path, text: /Mapa de trabajo/
  end

  private
    def serve(answer)
      ENV["WORK_MAP_SOURCE_FILE"] = work_map_file(answer)
    end

    def page_payload
      JSON.parse(css_select("script[data-work-map-target=data]").sole.text)
    end
end
