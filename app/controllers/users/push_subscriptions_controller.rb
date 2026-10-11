class Users::PushSubscriptionsController < ApplicationController
  wrap_parameters :push_subscription, include: %i[ endpoint p256dh_key auth_key client_id ]

  rate_limit to: 10, within: 10.minutes, by: -> { Current.user.id }, only: :create

  before_action :set_push_subscriptions

  def index
  end

  def create
    return head :forbidden unless Current.session && params[:user_id] == Current.user.id

    attributes = push_subscription_params.to_h.symbolize_keys
    subscription = Push::Subscription.for_endpoint(attributes[:endpoint])
    if subscription && !(subscription.authorized_for?(Current.user, Current.session) && subscription.matches_keys?(attributes))
      return head :conflict
    end

    Push::Subscription.register_for(Current.user, **attributes, session: Current.session, user_agent: request.user_agent)

    respond_to do |format|
      format.html { head :no_content }
      format.json { head :created }
    end
  rescue ActiveRecord::RecordNotUnique
    head :conflict
  rescue Push::Subscription::LimitExceeded
    head :too_many_requests
  end

  def destroy
    @push_subscriptions.destroy_by(id: params[:id])

    respond_to do |format|
      format.html { redirect_to user_push_subscriptions_url }
      format.json { head :no_content }
    end
  end

  private
    def set_push_subscriptions
      @push_subscriptions = Current.user.push_subscriptions
    end

    def push_subscription_params
      params.require(:push_subscription).permit(:endpoint, :p256dh_key, :auth_key, :client_id)
    end
end
