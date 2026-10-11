class Users::PushSubscriptionVerificationsController < ApplicationController
  def show
    subscription = Push::Subscription.find_signed(params[:token], purpose: :push_delivery)

    if subscription && params[:user_id] == Current.user.id && subscription.authorized_for?(Current.user, Current.session)
      head :no_content
    else
      head :forbidden
    end
  end

  def create
    attributes = params.require(:push_subscription).permit(:endpoint, :p256dh_key, :auth_key).to_h.symbolize_keys
    subscription = Push::Subscription.for_endpoint(attributes[:endpoint])

    if subscription && subscription.matches_keys?(attributes)
      subscription.with_lock do
        if params[:user_id] == Current.user.id && subscription.authorized_for?(Current.user, Current.session)
          head :no_content
        else
          subscription.destroy!
          head :conflict
        end
      end
    else
      head :conflict
    end
  rescue ActiveRecord::RecordNotFound
    head :conflict
  end
end
