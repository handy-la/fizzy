# Handy #2304: links and texts of the Power Through page.
module PowerThroughsHelper
  SUMMARY_LIMIT = 600

  def link_to_power_through(board)
    link_to board_power_through_path(board), class: "btn btn--circle-mobile",
      data: { controller: "tooltip", bridge__overflow_menu_target: "item", bridge_title: "Power Through" } do
      icon_tag("bolt") + tag.span("Power Through", class: "for-screen-reader")
    end
  end

  def power_through_card_path(power_through, card = nil)
    board_power_through_path(power_through.board, stages: power_through.selected_stage_ids.join(","), card: card&.number)
  end

  # What the card is about, from its own description: no text is generated.
  def power_through_summary(card)
    card.description.to_plain_text.to_s.squish.truncate(SUMMARY_LIMIT, separator: " ").presence
  end

  def power_through_neighbors(power_through, entry)
    entries = power_through.entries

    if entry && (index = power_through.index_of(entry))
      [ (entries[index - 1] if index > 0), entries[index + 1] ]
    else
      [ nil, entries.first ]
    end
  end

  def power_through_preferences(power_through)
    {
      account: Current.account.external_account_id,
      user: Current.user.id,
      board: power_through.board.id,
      stages: power_through.stages.map(&:id),
      selected: power_through.selected_stage_ids
    }
  end
end
