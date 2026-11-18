# Only invalidations travel through the stream. Every snapshot is read after
# checking access, including reconnects and revocation while already subscribed.
class TickHealthChannel < ActionCable::Channel::Base
  def subscribed
    if authorized?
      stream_from TickHealth.stream_name(@board) do |_notice|
        recover
      end
    else
      reject
    end
  end

  def recover
    if authorized?
      snapshot = TickHealth.snapshot(@board)
      if authorized?
        transmit snapshot
      else
        revoke
      end
    else
      revoke
    end
  end

  private
    def authorized?
      user = current_user.reload
      @board = user.boards.where(account_id: user.account_id).find_by(id: params[:board_id])
      user.active? && user.account.reload.active? && @board.present?
    rescue ActiveRecord::RecordNotFound
      false
    end

    def revoke
      stop_all_streams
      transmit({ error: "access_revoked", board_id: params[:board_id] })
    end
end
