class Cards::SuggestionsController < ApplicationController
  include CardScoped

  rate_limit to: 10, within: 1.minute, by: -> { Current.user.id }

  def create
    response.headers["Cache-Control"] = "no-store"
    if RubyLLM.config.openai_api_key.blank?
      head :service_unavailable
    elsif params[:kind] == "title" && @card.drafted? && @card.title.blank? && params[:description].present?
      render json: { suggestion: Card::Suggestion.new(@card, user: Current.user).title(params[:description].to_s) }
    elsif params[:kind] == "comment" && @card.commentable?
      render json: { suggestion: Card::Suggestion.new(@card, user: Current.user).comment }
    else
      head :no_content
    end
  rescue Card::Suggestion::ContextTooLarge
    head :unprocessable_entity
  rescue RubyLLM::Error, RubyLLM::ConfigurationError, Faraday::Error
    # Provider errors can include card text or credentials; never log the payload.
    head :service_unavailable
  end
end
