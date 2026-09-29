# Handy: the floating dock at the bottom of a card page. It follows the scroll
# once the card's top leaves the screen, and offers Done plus a move to the
# previous or next stage of the board.
module CardDockHelper
  Stage = Struct.new(:name, :url, :method, keyword_init: true)

  def card_dock_stages(card)
    return [ nil, nil ] unless card.open? && !card.postponed?

    if card.awaiting_triage?
      [ nil, card_dock_column_stage(card, card.board.columns.sorted.first) ]
    else
      [ card_dock_column_stage(card, card.column.left_column) || card_dock_triage_stage(card),
        card_dock_column_stage(card, card.column.right_column) ]
    end
  end

  def card_dock_stage_arc(stage, direction:)
    path_id = "card-dock-arc-#{direction}"

    tag.svg(class: "card-dock__arc", viewBox: "0 0 100 100", "aria-hidden": true) do
      tag.defs { tag.path(id: path_id, d: "M 17.09,69 A 38,38 0 1,1 82.91,69") } +
        tag.text(class: "card-dock__arc-text") do
          tag.textPath(stage.name.truncate(24, omission: "…"), href: "##{path_id}", startOffset: "50%", "text-anchor": "middle")
        end
    end
  end

  private
    def card_dock_column_stage(card, column)
      Stage.new(name: column.name, url: card_triage_path(card, column_id: column, from: "dock"), method: :post) if column
    end

    def card_dock_triage_stage(card)
      Stage.new(name: "Maybe?", url: card_triage_path(card, from: "dock"), method: :delete)
    end
end
