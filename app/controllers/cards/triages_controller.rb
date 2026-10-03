class Cards::TriagesController < ApplicationController
  include CardScoped, CardStageNavigation

  def create
    column = @card.board.columns.find(params[:column_id])
    capture_navigation_stage
    @card.triage_into(column)

    respond_to do |format|
      format.html do
        offer_next_card_after_move(to: column.id)
        redirect_to @card
      end
      format.json { head :no_content }
    end
  end

  def destroy
    capture_navigation_stage
    @card.send_back_to_triage

    respond_to do |format|
      format.html do
        offer_next_card_after_move(to: "maybe")
        redirect_to @card
      end
      format.json { head :no_content }
    end
  end
end
