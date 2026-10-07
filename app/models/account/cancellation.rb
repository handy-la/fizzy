class Account::Cancellation < ApplicationRecord
  belongs_to :account
  belongs_to :initiated_by, class_name: "User"

  after_create :revoke_suggestions
  after_create_commit :close_remote_connections

  private
    def revoke_suggestions
      Card::SuggestionRequest.revoke_for_account(account)
    end

    def close_remote_connections
      account.users.find_each(&:close_remote_connections)
    end
end
