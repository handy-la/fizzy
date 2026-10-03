class Cards::NotNowsController < ApplicationController
  include CardScoped, CardStageNavigation

  def create
    capture_card_location
    capture_navigation_stage unless @card.postponed?
    @card.postpone
    refresh_stream_if_needed

    respond_to do |format|
      format.turbo_stream
      format.json { head :no_content }
    end
  end
end
