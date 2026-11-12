require "test_helper"

# Authoring answers: docs/test-audits/handy-2348.md.
class WorkMapTest < ActiveSupport::TestCase
  include WorkMapTestHelper

  setup do
    Current.session = sessions(:kevin)
    @writebook = boards(:writebook)
    @private = boards(:private)
    # The private board is Kevin's only; David sees Writebook alone.
    @secret = @private.cards.create!(title: "Plan secreto", creator: users(:kevin), status: "published")
  end

  test "without the source every accessible board is a product and every open card a node" do
    map = WorkMap.new(user: users(:kevin), source: WorkMap::Source.new)

    assert_equal "not_configured", map.result.status
    assert_equal [ "Private board", "Writebook" ], map.products.map(&:name)
    assert map.products.all? { |product| product.status == "source_not_configured" }

    numbers = map.nodes.map { |node| node.card.number }
    assert_includes numbers, @secret.number
    assert_includes numbers, cards(:buy_domain).number, "a card in Maybe? stays on the map"
    assert_not_includes numbers, cards(:shipping).number, "a closed card with no relation is not loaded"
    assert map.nodes.all? { |node| node.execution_status == "source_not_configured" }
    assert_empty map.edges
  end

  test "Maybe?, Not Now and a column are told apart, and a postponed card stays" do
    cards(:logo).postpone(user: users(:kevin))
    map = WorkMap.new(user: users(:kevin), source: WorkMap::Source.new)
    by_number = map.nodes.index_by { |node| node.card.number }

    assert_equal [ "maybe", "Maybe?" ], [ by_number[cards(:buy_domain).number].disposition, by_number[cards(:buy_domain).number].stage_name ]
    assert_equal [ "not_now", "Not Now" ], [ by_number[cards(:logo).number].disposition, by_number[cards(:logo).number].stage_name ]
    assert_equal [ "column", "In progress" ], [ by_number[cards(:text).number].disposition, by_number[cards(:text).number].stage_name ]
  end

  test "products come from Dédalo's registry at run time, and a new product appears with no code change" do
    answer = work_map_answer(products: [ work_map_product("alpha", @writebook, name: "Alpha"),
      work_map_product("producto-nuevo", @private, name: "Producto nuevo") ])
    map = WorkMap.new(user: users(:kevin), source: work_map_source(answer))

    assert_equal %w[ alpha producto-nuevo ], map.products.map(&:key)
    assert_equal "producto-nuevo", map.nodes.find { |node| node.card == @secret }.product.key
  end

  test "a cross-product chain A → B → C keeps each relation and its condition" do
    a, b, c = @secret, cards(:text), cards(:logo)
    answer = work_map_answer(
      products: [ work_map_product("alpha", @writebook), work_map_product("beta", @private) ],
      items: [ work_map_item("alpha", b, state: "held", wait: work_map_wait(kind: "card")) ],
      relations: [ work_map_relation([ "beta", a ], [ "alpha", b ], condition: "publication"),
        work_map_relation([ "alpha", b ], [ "alpha", c ], condition: "integration") ])
    map = WorkMap.new(user: users(:kevin), source: work_map_source(answer))

    assert_equal [ [ "card-#{a.number}", "card-#{b.number}", "publication" ], [ "card-#{b.number}", "card-#{c.number}", "integration" ] ],
      map.edges.map { |edge| [ edge.from, edge.to, edge.condition ] }
    node_b = map.nodes.find { |node| node.card == b }
    assert_equal "held", node_b.execution["state"]
    assert_equal "card", node_b.execution["wait"]["kind"]
  end

  test "several blockers keep their own satisfaction, and closing a prerequisite does not satisfy it" do
    cards(:logo).close(user: users(:kevin))
    answer = work_map_answer(
      products: [ work_map_product("alpha", @writebook) ],
      relations: [ work_map_relation([ "alpha", cards(:logo) ], [ "alpha", cards(:text) ], status: "pending"),
        work_map_relation([ "alpha", cards(:layout) ], [ "alpha", cards(:text) ], status: "satisfied", resolved_at: "2026-11-12T18:30:00Z"),
        work_map_relation([ "alpha", cards(:shipping) ], [ "alpha", cards(:text) ], status: "reconciled") ])
    map = WorkMap.new(user: users(:kevin), source: work_map_source(answer))

    assert_equal %w[ pending satisfied reconciled ], map.edges.map(&:status)
    closed = map.nodes.find { |node| node.card == cards(:logo) }
    assert_equal "closed", closed.disposition, "a closed prerequisite of a chain is shown"
    assert_equal "pending", map.edges.first.status, "its relation is still in force"
  end

  test "an endpoint on a board the person cannot access keeps no identity" do
    answer = work_map_answer(
      products: [ work_map_product("alpha", @writebook), work_map_product("beta", @private) ],
      relations: [ work_map_relation([ "beta", @secret ], [ "alpha", cards(:text) ]),
        work_map_relation([ "beta", @secret ], [ "alpha", cards(:logo) ]) ])
    map = WorkMap.new(user: users(:david), source: work_map_source(answer))

    assert_equal %w[ alpha ], map.products.map(&:key), "another product's existence is not shown"
    assert_not map.nodes.any? { |node| node.card == @secret }
    assert_equal [ "inaccessible", "inaccessible" ], map.placeholders.map(&:kind)
    assert map.placeholders.all? { |placeholder| placeholder.product.nil? && placeholder.number.nil? }
    assert_equal 2, map.placeholders.map(&:id).uniq.size, "two relations cannot show that they share a hidden card"
  end

  test "a relation between two cards the person cannot see is dropped" do
    other = @private.cards.create!(title: "Otro secreto", creator: users(:kevin), status: "published")
    answer = work_map_answer(products: [ work_map_product("beta", @private) ],
      relations: [ work_map_relation([ "beta", @secret ], [ "beta", other ]) ])
    map = WorkMap.new(user: users(:david), source: work_map_source(answer))

    assert_empty map.edges
    assert_empty map.placeholders
  end

  test "a draft is hidden like another board, never called missing" do
    draft = @writebook.cards.create!(title: "Borrador de Kevin", creator: users(:kevin), status: "drafted")
    answer = work_map_answer(products: [ work_map_product("alpha", @writebook) ],
      relations: [ work_map_relation([ "alpha", draft ], [ "alpha", cards(:text) ]) ])
    map = WorkMap.new(user: users(:david), source: work_map_source(answer))

    assert_equal [ "inaccessible" ], map.placeholders.map(&:kind)
  end

  test "a card that does not exist on an accessible board is a missing reference" do
    answer = work_map_answer(products: [ work_map_product("alpha", @writebook) ],
      relations: [ work_map_relation([ "alpha", 987_654 ], [ "alpha", cards(:text) ]) ])
    map = WorkMap.new(user: users(:david), source: work_map_source(answer))

    placeholder = map.placeholders.sole
    assert_equal [ "missing", "alpha", 987_654 ], [ placeholder.kind, placeholder.product.key, placeholder.number ]
    assert_equal placeholder.id, map.edges.sole.from
  end

  test "a cycle keeps both relations" do
    answer = work_map_answer(products: [ work_map_product("alpha", @writebook) ],
      relations: [ work_map_relation([ "alpha", cards(:text) ], [ "alpha", cards(:logo) ]),
        work_map_relation([ "alpha", cards(:logo) ], [ "alpha", cards(:text) ]) ])
    map = WorkMap.new(user: users(:david), source: work_map_source(answer))

    assert_equal 2, map.edges.size
  end

  test "no execution data is told apart from a failed or incomplete source" do
    answer = work_map_answer(products: [ work_map_product("alpha", @writebook), work_map_product("beta", @private, status: "failed", error: "beads_unavailable") ],
      items: [ work_map_item("alpha", cards(:text)) ])
    map = WorkMap.new(user: users(:kevin), source: work_map_source(answer))
    status = map.nodes.to_h { |node| [ node.card, node.execution_status ] }

    assert_equal "reported", status[cards(:text)]
    assert_equal "none_reported", status[cards(:logo)]
    assert_equal "product_failed", status[@secret]
    assert_equal "beads_unavailable", map.products.find { |product| product.key == "beta" }.error

    partial = work_map_answer(products: [ work_map_product("alpha", @writebook, status: "partial") ])
    assert WorkMap.new(user: users(:david), source: work_map_source(partial)).nodes.all? { |node| node.execution_status == "incomplete" }

    truncated = work_map_answer(products: [ work_map_product("alpha", @writebook, truncated: true) ])
    assert WorkMap.new(user: users(:david), source: work_map_source(truncated)).nodes.all? { |node| node.execution_status == "incomplete" }
  end

  test "a failed source keeps every card and says so for every product" do
    map = WorkMap.new(user: users(:kevin), source: work_map_source("{ not json"))

    assert_equal [ "failed", "invalid_json" ], [ map.result.status, map.result.error ]
    assert map.products.all? { |product| product.status == "source_failed" }
    assert_includes map.nodes.map(&:card), @secret
    assert map.nodes.all? { |node| node.execution_status == "source_failed" }
  end

  test "a board Dédalo does not register is its own product, with no execution expected" do
    answer = work_map_answer(products: [ work_map_product("alpha", @writebook) ])
    map = WorkMap.new(user: users(:kevin), source: work_map_source(answer))

    unregistered = map.products.find { |product| product.board_id == @private.id }
    assert_equal [ "board-#{@private.id}", "Private board", "unregistered" ], [ unregistered.key, unregistered.name, unregistered.status ]
    assert_equal "unregistered", map.nodes.find { |node| node.card == @secret }.execution_status
  end

  test "the open inventory is bounded and says when it is cut" do
    map = WorkMap.new(user: users(:kevin), source: WorkMap::Source.new, max_cards: 2)

    assert map.truncated?
    assert_equal 2, map.nodes.size
    assert_not WorkMap.new(user: users(:kevin), source: WorkMap::Source.new).truncated?
  end
end
