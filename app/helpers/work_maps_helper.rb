# Handy #2348: the only data the work map page gives the browser. Each field
# is listed here on purpose; nothing is serialized whole (no record, no
# snapshot, no raw item), so a field added to a model or to Dédalo's answer
# never reaches the page by accident. Contract: docs/work-map.md.
module WorkMapsHelper
  def work_map_payload(work_map)
    {
      generated_at: Time.current.utc.iso8601,
      source: work_map_source(work_map),
      truncated: work_map.truncated?,
      max_cards: work_map.max_cards,
      products: work_map.products.map { |product| work_map_product(product) },
      nodes: work_map.nodes.map { |node| work_map_node(node) } + work_map.placeholders.map { |placeholder| work_map_placeholder(placeholder) },
      edges: work_map.edges.map { |edge| work_map_edge(edge) }
    }
  end

  def work_map_json(work_map)
    json_escape(work_map_payload(work_map).to_json).html_safe
  end

  private
    def work_map_source(work_map)
      snapshot = work_map.snapshot
      { status: work_map.result.status, error: work_map.result.error, generated_at: snapshot&.generated_at,
        dropped: snapshot&.dropped.to_h.sum { |_, count| count }, over_limit: Array(snapshot&.over_limit) }
    end

    def work_map_product(product)
      { key: product.key, name: product.name, status: product.status, read_at: product.read_at,
        error: product.error, truncated: product.truncated }
    end

    def work_map_node(node)
      card = node.card
      { id: node.id, kind: "card", product: node.product.key, number: card.number,
        title: card.title.to_s.truncate(WorkMap::MAX_TITLE), url: card_path(card),
        disposition: node.disposition, stage: node.stage_name, closed_at: card.closed_at&.utc&.iso8601,
        execution_status: node.execution_status, execution: work_map_execution(node.execution) }
    end

    def work_map_execution(execution)
      if execution
        { state: execution["state"], wait: execution["wait"]&.slice(*WorkMap::Snapshot::WAIT_KEYS),
          milestones: execution["milestones"].slice(*WorkMap::Snapshot::MILESTONE_KEYS) }
      end
    end

    def work_map_placeholder(placeholder)
      { id: placeholder.id, kind: placeholder.kind, product: placeholder.product&.key, number: placeholder.number }
    end

    def work_map_edge(edge)
      { from: edge.from, to: edge.to, condition: edge.condition, environment: edge.environment, channel: edge.channel,
        status: edge.status, since: edge.since, resolved_at: edge.resolved_at }
    end
end
