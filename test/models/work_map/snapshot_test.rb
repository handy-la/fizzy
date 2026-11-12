require "test_helper"

# Authoring answers: docs/test-audits/handy-2348.md.
class WorkMap::SnapshotTest < ActiveSupport::TestCase
  include WorkMapTestHelper

  test "a contract answer keeps only the allowed fields" do
    snapshot = WorkMap::Snapshot.parse(answer)

    assert_equal [ "alpha" ], snapshot.products.map { |product| product["id"] }
    assert_equal WorkMap::Snapshot::PRODUCT_KEYS.sort, snapshot.products.first.keys.sort
    assert_equal WorkMap::Snapshot::WAIT_KEYS.sort, snapshot.items.first["wait"].keys.sort
    assert_equal "pending", snapshot.relations.first["status"]
    assert_empty snapshot.dropped
  end

  test "an object with a key outside the contract is dropped whole and counted" do
    data = answer
    data["items"].first["claim_token"] = "fake-claim-token-not-real"
    data["relations"].first["prompt"] = "texto del agente"
    data["products"].first["error"] = "/home/hermes/.dedalo/handy/beads exploded"
    snapshot = WorkMap::Snapshot.parse(data)

    assert_empty snapshot.items
    assert_empty snapshot.relations
    assert_empty snapshot.products, "an error is a short code, never a message or a path"
    assert_equal({ "items" => 1, "relations" => 1, "products" => 1 }, snapshot.dropped)
  end

  test "values out of range, bad dates and bad identities are dropped" do
    data = answer
    data["items"] << work_map_item("alpha", 2, wait: work_map_wait(kind: "agent_idle"))
    data["items"] << work_map_item("alpha", 3, wait: work_map_wait(since: "ayer"))
    data["items"] << work_map_item("Alpha Upper", 4)
    data["items"] << work_map_item("alpha", -4)
    data["relations"] << work_map_relation([ "alpha", 1 ], [ "alpha", 2 ], status: "closed")
    data["relations"] << work_map_relation([ "alpha", 1 ], [ "alpha", 2 ], condition: "merged")
    snapshot = WorkMap::Snapshot.parse(data)

    assert_equal 1, snapshot.items.size
    assert_equal 1, snapshot.relations.size
    assert_equal({ "items" => 4, "relations" => 2 }, snapshot.dropped)
  end

  test "free text is plain, one line and bounded" do
    data = answer
    data["items"].first["wait"]["reason"] = "Línea uno\nLínea\u0007 dos <b>"
    snapshot = WorkMap::Snapshot.parse(data)

    assert_equal "Línea uno Línea dos <b>", snapshot.items.first["wait"]["reason"]

    data["items"].first["wait"]["reason"] = "x" * 281
    assert_empty WorkMap::Snapshot.parse(data).items
  end

  test "an unknown schema or a broken envelope is refused" do
    assert_raises(WorkMap::Snapshot::Invalid) { WorkMap::Snapshot.parse(answer.merge("schema" => 2)) }
    assert_raises(WorkMap::Snapshot::Invalid) { WorkMap::Snapshot.parse(answer.except("relations")) }
    assert_raises(WorkMap::Snapshot::Invalid) { WorkMap::Snapshot.parse(answer.merge("extra" => 1)) }
    assert_raises(WorkMap::Snapshot::Invalid) { WorkMap::Snapshot.parse(answer.merge("items" => {})) }
    assert_raises(WorkMap::Snapshot::Invalid) { WorkMap::Snapshot.parse([]) }
  end

  test "more entries than the limit are cut and reported" do
    data = answer(items: Array.new(WorkMap::Snapshot::MAX_ITEMS + 1) { |index| work_map_item("alpha", index + 1) })
    snapshot = WorkMap::Snapshot.parse(data)

    assert_equal WorkMap::Snapshot::MAX_ITEMS, snapshot.items.size
    assert_equal [ "items" ], snapshot.over_limit
  end

  private
    def answer(items: [ work_map_item("alpha", 1, state: "held", wait: work_map_wait) ])
      work_map_answer(
        products: [ work_map_product("alpha", boards(:writebook)) ],
        items: items,
        relations: [ work_map_relation([ "alpha", 1 ], [ "alpha", 2 ]) ]).deep_dup
    end
end
