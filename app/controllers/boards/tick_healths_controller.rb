class Boards::TickHealthsController < ApplicationController
  include BoardScoped

  def show
    response.headers["Cache-Control"] = "no-store"
    render json: TickHealth.snapshot(@board)
  end

  def update
    if request.raw_post.bytesize > 8.kilobytes
      render status: :payload_too_large, json: { error: "body_too_large" }
    elsif !request.content_mime_type&.json?
      render status: :unsupported_media_type, json: { error: "json_required" }
    else
      result = TickHealth::Declaration.write(board: @board, stage_id: params[:stage_id], body: JSON.parse(request.raw_post), user: Current.user)
      if result.status.in?(%i[ ok created ])
        render status: result.status, json: TickHealth.snapshot(@board).merge(result: result.code)
      else
        render status: result.status, json: { error: result.code, details: result.details }
      end
    end
  rescue JSON::ParserError
    render status: :bad_request, json: { error: "invalid_json" }
  end
end
