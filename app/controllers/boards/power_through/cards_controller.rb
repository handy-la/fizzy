# Handy #2304: the current verdict on one card, read again before a reply is
# posted so a request that changed while someone wrote is never answered blind.
class Boards::PowerThrough::CardsController < ApplicationController
  include BoardScoped

  def show
    @card = Current.user.accessible_cards.find_by!(board: @board, number: params[:id])
    @request = Card::PendingRequest.for(@card)
  end
end
