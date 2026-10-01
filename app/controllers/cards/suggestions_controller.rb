class Cards::SuggestionsController < ApplicationController
  include CardScoped

  rate_limit to: 10, within: 1.minute, by: -> { Current.user.id }, only: :create
  before_action -> { response.headers["Cache-Control"] = "no-store" }

  def create
    if RubyLLM.config.openai_api_key.blank?
      head :service_unavailable
    elsif params[:kind] == "title" && @card.drafted? && @card.title.blank? && sufficient_description?
      accept_request("title", params[:description].to_s)
    elsif params[:kind] == "comment" && @card.commentable?
      accept_request("comment")
    else
      head :no_content
    end
  end

  def show
    request = Card::SuggestionRequest.find_by!(card: @card, user: Current.user, token: params[:request_id])
    render json: request.state, status: request.reload.status.in?(%w[ pending running ]) ? :accepted : :ok
  end

  private
    def sufficient_description?
      description = params[:description].to_s
      description.bytesize <= Card::Suggestion::CONTEXT_LIMIT && ActionText::Content.new(description).to_plain_text.strip.length >= 20
    end

    def accept_request(kind, description = nil)
      request = Card::SuggestionRequest.request(@card, user: Current.user, kind: kind, description: description)
      render json: request.state, status: :accepted
    end
end
