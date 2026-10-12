class Webhooks::ActivationsController < ApplicationController
  include BoardScoped

  before_action :ensure_admin

  def create
    @webhook = @board.webhooks.find(params[:webhook_id])

    if @webhook.activate
      respond_to do |format|
        format.html { redirect_to @webhook }
        format.json { render "webhooks/show", status: :created }
      end
    else
      respond_to do |format|
        format.html { redirect_to @webhook, alert: @webhook.errors.full_messages.to_sentence }
        format.json { render json: @webhook.errors, status: :unprocessable_entity }
      end
    end
  end
end
