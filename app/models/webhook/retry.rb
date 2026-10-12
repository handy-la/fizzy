class Webhook::Retry < ApplicationRecord
  LIMIT = 60
  WINDOW = 1.hour

  belongs_to :account

  # The caller holds the account write lock until it claims the delivery.
  def self.reserve(account)
    retries = where(account: account)
    retries.where(created_at: ...WINDOW.ago).delete_all
    if retries.count < LIMIT
      create!(account: account)
      true
    else
      false
    end
  end
end
