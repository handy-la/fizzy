class Cards::TriagesController < ApplicationController
  include CardScoped

  def create
    column = @card.board.columns.find(params[:column_id])
    source_column = @card.column
    @card.triage_into(column)

    respond_to do |format|
      format.html do
        offer_next_card_awaiting_approval(from: source_column, to: column)
        redirect_to @card
      end
      format.json { head :no_content }
    end
  end

  def destroy
    @card.send_back_to_triage

    respond_to do |format|
      format.html { redirect_to @card }
      format.json { head :no_content }
    end
  end

  private
    # Handy: moving a card forward out of AWAITING APPROVAL from the card dock
    # offers the next card still waiting there, to approve one after another.
    def offer_next_card_awaiting_approval(from:, to:)
      if params[:from] == "dock" && from&.awaiting_approval? && to.position > from.position
        flash[:approved_from_column_id] = from.id
      end
    end
end
