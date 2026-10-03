module CardStageNavigation
  extend ActiveSupport::Concern

  Stage = Data.define(:name, :color, :cards)

  included do
    helper_method :card_navigation_stage
  end

  private
    def capture_navigation_stage
      @source_stage_id = if @card.closed?
        "done"
      elsif @card.postponed?
        "not_now"
      else
        @card.column_id || "maybe"
      end
    end

    def offer_next_card_after_move(to:)
      if @source_stage_id != to
        flash[:next_card_from_stage] = @source_stage_id
      end
    end

    def card_navigation_stage(stage_id)
      board = @card.board

      case stage_id
      when "maybe"
        Stage.new(name: "Maybe?", color: "var(--color-card-default)", cards: board.cards.awaiting_triage)
      when "not_now"
        Stage.new(name: "Not now", color: "var(--color-card-complete)", cards: board.cards.postponed)
      when "done"
        Stage.new(name: "Done", color: "var(--color-card-complete)", cards: board.cards.closed.published)
      else
        if column = board.columns.find_by(id: stage_id)
          Stage.new(name: column.name, color: column.color, cards: column.cards.active)
        end
      end
    end
end
