class Notification::PushTarget::Web < Notification::PushTarget
  def process
    if subscriptions.any?
      Rails.configuration.x.web_push_pool.queue(notification.payload.to_h, subscriptions)
    end
  end

  private
    def subscriptions
      # Bound fan-out also for subscriptions created before the quota existed.
      @subscriptions ||= notification.user.push_subscriptions.active.order(updated_at: :desc, id: :desc).limit(Push::Subscription::MAX_PER_USER)
    end
end
