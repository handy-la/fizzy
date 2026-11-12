# Automatic waits on a card, for an external producer (Dédalo). Authentication
# is the existing one (session or bearer token; a read-only token cannot
# write), and every request resolves the card through the user's accessible
# cards in the current account, so account, board access and card membership
# are checked on each operation. The body is a bounded JSON object read as is:
# an unknown property is refused, never ignored. Contract: docs/automatic-waits.md.
class Cards::AutomaticWaitsController < ApplicationController
  include CardScoped

  STATUS = {
    created: :created, updated: :ok, replayed: :ok, cleared: :ok,
    invalid: :unprocessable_entity, conflict: :conflict, not_found: :not_found
  }.freeze

  # Codes that a retry with the same body can never satisfy, but which are about
  # the request rather than the state it raced with.
  UNPROCESSABLE_CONFLICTS = %i[ too_many_waits ].freeze

  def index
    render_summary
  end

  def update
    with_body { |body| answer Card::AutomaticWait::Declaration.declare(card: @card, key: params[:key], body: body, user: Current.user) }
  end

  def destroy
    with_body { |body| answer Card::AutomaticWait::Declaration.clear(card: @card, key: params[:key], body: body, user: Current.user) }
  end

  private
    def with_body
      if request.raw_post.bytesize > Card::AutomaticWait::Declaration::MAX_BODY_BYTES
        render_error :payload_too_large, :body_too_large
      elsif !request.content_mime_type&.json?
        render_error :unsupported_media_type, :json_required
      else
        yield JSON.parse(request.raw_post)
      end
    rescue JSON::ParserError
      render_error :bad_request, :invalid_json
    end

    def answer(result)
      if result.success?
        @card.reload
        render_summary status: STATUS.fetch(result.status), result: result
      else
        status = result.code.in?(UNPROCESSABLE_CONFLICTS) ? :unprocessable_entity : STATUS.fetch(result.status)
        render_error status, result.code, details: result.details
      end
    end

    def render_summary(status: :ok, result: nil)
      @result = result
      @summary = @card.automatic_wait_summary
      render :index, status: status
    end

    def render_error(status, code, details: nil)
      render status: status, json: { error: code.to_s, details: details }.compact
    end
end
