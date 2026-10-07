class CardSuggestionChannel < ActionCable::Channel::Base
  def subscribed
    if authorized_request
      stream_from @request.stream_name do |_notification|
        recover
      end
    else
      reject
    end
  end

  # Called after subscription confirmation and on every reconnect, closing the
  # race between the HTTP response, broadcast and actual stream subscription.
  def recover
    state = @request.state if authorized_request
    if state && authorized_request
      transmit state.merge(revision: params[:revision])
    else
      stop_all_streams
      transmit({ request_id: params[:token], revision: params[:revision], status: "failed", error_category: "access_revoked" })
    end
  end

  private
    def authorized_request
      user = current_user.reload
      @request = Card::SuggestionRequest.find_by(user: user, token: params[:token])
      user.active? && user.account.reload.active? && @request && user.accessible_cards.where(account_id: user.account_id).exists?(id: @request.card_id)
    rescue ActiveRecord::RecordNotFound
      false
    end
end
