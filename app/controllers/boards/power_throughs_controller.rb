# Handy #2304: answer, one card after another, what a board's cards ask of a
# person. Reading this page writes nothing; only the comment form posts.
class Boards::PowerThroughsController < ApplicationController
  include BoardScoped

  def show
    @power_through = Board::PowerThrough.new(board: @board, user: Current.user, stage_ids: params[:stages])
    @explicit_stages = params[:stages].present?
    set_focus

    pin_focus if params[:card].blank? && @entry
  end

  private
    def set_focus
      if params[:card].present? && (@entry = @power_through.entry_for(params[:card])).nil?
        @resolved_card = Current.user.accessible_cards.active.find_by(board: @board, number: params[:card].to_i)
      end

      @entry ||= @power_through.entries.first unless @resolved_card
    end

    # The focused card is always in the URL: a live refresh reloads this same
    # URL, and without it a card answered elsewhere would hand the screen to
    # the next card while someone writes.
    def pin_focus
      redirect_to board_power_through_path(@board, stages: params[:stages].presence, card: @entry.card.number)
    end
end
