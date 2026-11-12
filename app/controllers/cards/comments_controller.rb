class Cards::CommentsController < ApplicationController
  wrap_parameters :comment, include: %i[ body created_at client_token ]
  include CardScoped

  before_action :set_comment, only: %i[ show edit update destroy ]
  before_action :ensure_creatorship, only: %i[ edit update destroy ]
  before_action :ensure_card_is_commentable, only: :create

  def index
    set_page_and_extract_portion_from @card.comments.chronologically
  end

  def create
    if @comment = submitted_comment
      replay_create
    else
      @comment = @card.comments.create!(comment_params)

      respond_to do |format|
        format.turbo_stream
        format.json { render :show, status: :created, location: card_comment_path(@card, @comment, format: :json) }
      end
    end
  rescue ActiveRecord::RecordNotUnique
    @comment = submitted_comment or raise
    replay_create
  end

  def show
  end

  def edit
  end

  def update
    @comment.update! comment_params

    respond_to do |format|
      format.turbo_stream
      format.json { render :show }
    end
  end

  def destroy
    @comment.destroy

    respond_to do |format|
      format.turbo_stream
      format.json { head :no_content }
    end
  end

  private
    def set_comment
      @comment = @card.comments.find(params[:id])
    end

    def ensure_creatorship
      head :forbidden if Current.user != @comment.creator
    end

    def ensure_card_is_commentable
      head :forbidden unless @card.commentable?
    end

    def comment_params
      params.expect(comment: [ :body, :created_at, :client_token ])
    end

    # Handy #2304: the same client token from the same person on the same card
    # is the same comment. A retry after a timeout or a second click answers
    # with the comment that already landed instead of posting it again.
    def submitted_comment
      if token = params.dig(:comment, :client_token).presence
        @card.comments.find_by(creator: Current.user, client_token: token)
      end
    end

    # The client cannot tell from the comment's rendering whether what landed is
    # the text it sends now or an earlier version of it, so the replay says so.
    def replay_create
      response.headers["Comment-Replay"] = submitted_body_landed? ? "same" : "different"

      respond_to do |format|
        format.turbo_stream { head :ok }
        format.json { render :show, status: :ok, location: card_comment_path(@card, @comment, format: :json) }
      end
    end

    def submitted_body_landed?
      ActionText::Content.new(params.dig(:comment, :body).to_s).to_html == @comment.body.body.to_html
    end
end
