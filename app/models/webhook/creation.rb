class Webhook::Creation < ApplicationRecord
  LIMIT = 10
  WINDOW = 1.minute

  belongs_to :account

  def self.admit(account)
    transaction do
      Account.where(id: account.id).update_all("updated_at = updated_at")
      creations = where(account: account)
      creations.where(created_at: ...WINDOW.ago).delete_all
      if creations.count < LIMIT
        create!(account: account)
        true
      else
        false
      end
    end
  end
end
