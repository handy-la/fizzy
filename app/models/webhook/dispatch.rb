# One durable wakeup for all pending deliveries. Only this pump sends HTTP.
class Webhook::Dispatch < ApplicationRecord
  SINGLETON_ID = "0000000000000000000000001"
  LEASE = 5.minutes

  def self.synchronize
    create_or_find_by!(id: SINGLETON_ID)
    transaction do
      where(id: SINGLETON_ID).update_all("value = value + 1")
      yield find(SINGLETON_ID)
    end
  end

  def self.schedule
    token = synchronize do |dispatch|
      if !dispatch.leased_until&.future? && dispatch.next_delivery
        token = SecureRandom.hex(16)
        dispatch.update!(token: token, leased_until: LEASE.from_now, running: false)
        token
      end
    end
    # Global jobs must survive cancellation/incineration of the triggering account.
    if token
      Current.with_account(nil) { Webhook::DispatchJob.perform_later(token) }
    end
  end

  def self.run(token)
    acquired = false
    delivery = synchronize do |dispatch|
      if dispatch.token == token && !dispatch.running? && dispatch.leased_until&.future?
        acquired = true
        dispatch.update!(running: true, leased_until: LEASE.from_now)
        if delivery = dispatch.next_delivery
          dispatch.update!(last_account_id: delivery.account_id)
          delivery
        end
      end
    end
    if delivery
      Current.with_account(delivery.account) { delivery.deliver }
    end
  ensure
    released = acquired && synchronize do |dispatch|
      if dispatch.token == token
        dispatch.update!(token: nil, leased_until: nil, running: false)
        true
      end
    end
    schedule if released
  end

  def self.recover
    Webhook::Delivery.in_progress.where(updated_at: ..Webhook::Delivery::STALLED_AFTER.ago)
      .update_all(state: :pending, updated_at: Time.current)
    Webhook::Creation.where(created_at: ...Webhook::Creation::WINDOW.ago).delete_all
    Webhook::Retry.where(created_at: ...Webhook::Retry::WINDOW.ago).delete_all
    schedule
  end

  def next_delivery
    pending = Webhook::Delivery.pending
    accounts = pending.distinct.pluck(:account_id).sort
    after, before = accounts.partition { |id| last_account_id.nil? || id > last_account_id }
    (after + before).each do |account_id|
      # Includes old backlogs: never load more than the admission cap at once.
      pending.where(account_id: account_id).order(:created_at, :id).limit(Webhook::Delivery::PENDING_LIMIT).each do |delivery|
        return delivery if delivery.ready?
      end
    end
    nil
  end
end
