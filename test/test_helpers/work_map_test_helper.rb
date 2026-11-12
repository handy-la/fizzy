# Handy #2348: builds Dédalo's answer for the work map (docs/work-map.md) the
# way the producer sends it, and hands it to the map through the sample-file
# source, the same path a person uses to show the map with sample data.
module WorkMapTestHelper
  GENERATED_AT = "2026-11-12T19:00:00Z"

  def work_map_answer(products: [], items: [], relations: [], generated_at: GENERATED_AT, schema: 1)
    { "schema" => schema, "generated_at" => generated_at, "products" => products, "items" => items, "relations" => relations }
  end

  def work_map_product(id, board, status: "ok", name: id.titleize, **extra)
    { "id" => id, "name" => name, "board_id" => board.id, "status" => status, "read_at" => GENERATED_AT,
      "error" => nil, "truncated" => false }.merge(extra.stringify_keys)
  end

  def work_map_item(product, card, state: "working", wait: nil, milestones: nil)
    { "product" => product, "card" => card.is_a?(Card) ? card.number : card, "state" => state, "wait" => wait,
      "milestones" => milestones || { "integrated_at" => nil, "deployed_at" => nil, "published_at" => nil } }
  end

  def work_map_wait(kind: "card", reason: "Espera otra entrega", since: "2026-11-12T18:00:00Z", checked_at: "2026-11-12T18:55:00Z",
    human: "not_required", next_step: nil)
    { "kind" => kind, "reason" => reason, "since" => since, "checked_at" => checked_at, "human" => human, "next_step" => next_step }
  end

  def work_map_relation(prerequisite, dependent, condition: "integration", status: "pending", since: "2026-11-12T18:00:00Z", resolved_at: nil)
    { "prerequisite" => work_map_endpoint(prerequisite), "dependent" => work_map_endpoint(dependent),
      "condition" => condition, "environment" => nil, "channel" => nil, "status" => status, "since" => since, "resolved_at" => resolved_at }
  end

  def work_map_endpoint((product, card))
    { "product" => product, "card" => card.is_a?(Card) ? card.number : card }
  end

  # A Source that reads `answer` from a sample file, with its own cache.
  def work_map_source(answer)
    WorkMap::Source.new(file: work_map_file(answer), cache: ActiveSupport::Cache::NullStore.new)
  end

  def work_map_file(answer)
    file = Tempfile.new([ "work-map", ".json" ])
    file.write(answer.is_a?(String) ? answer : answer.to_json)
    file.close
    (@work_map_files ||= []) << file
    file.path
  end
end
