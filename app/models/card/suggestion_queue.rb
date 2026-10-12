class Card::SuggestionQueue < ApplicationRecord
  SINGLETON_ID = "0000000000000000000000001"
  USER_LIMIT = 1
  ACCOUNT_LIMIT = 2
  GLOBAL_LIMIT = 4
  ACCOUNT_BUDGET = 10
  GLOBAL_BUDGET = 30
  BUDGET_WINDOW = 1.hour

  class Full < StandardError; end

  def self.synchronize
    create_or_find_by!(id: SINGLETON_ID)
    transaction do
      # A write before any reads serializes admission and dispatch on SQLite
      # as well as MySQL. Never hold this lock during the provider call.
      where(id: SINGLETON_ID).update_all("value = value + 1")
      yield find(SINGLETON_ID)
    end
  end

  def self.generate_next
    if request = create_or_find_by!(id: SINGLETON_ID).next_request
      Current.with_account(request.user.account) { request.generate(request.token) }
    end
  end

  def reserve(user)
    active = Card::SuggestionRequest.where(status: %w[ pending running ], expires_at: Time.current..)
    account = active.joins(:user).where(users: { account_id: user.account_id })
    raise Full if active.where(user: user).count >= USER_LIMIT || account.count >= ACCOUNT_LIMIT || active.count >= GLOBAL_LIMIT

    Card::SuggestionAdmission.where(created_at: ...BUDGET_WINDOW.ago).delete_all
    admissions = Card::SuggestionAdmission.all
    raise Full if admissions.where(account_id: user.account_id).count >= ACCOUNT_BUDGET || admissions.count >= GLOBAL_BUDGET

    Card::SuggestionAdmission.create!(account_id: user.account_id)
  end

  def next_request
    pending = Card::SuggestionRequest.joins(:user).where(status: "pending", expires_at: Time.current..)
    accounts = pending.distinct.pluck("users.account_id").sort
    account_id = accounts.find { |id| last_account_id.nil? || id > last_account_id } || accounts.first
    pending.where(users: { account_id: account_id }).order(:requested_at, :id).first if account_id
  end

  def start(request, token)
    return false if Card::SuggestionRequest.where(status: "running", expires_at: Time.current..).exists?
    return false unless next_request&.id == request.id

    if Card::SuggestionRequest.where(id: request.id, token: token, status: "pending", expires_at: Time.current..)
        .update_all(status: "running", started_at: Time.current, expires_at: Card::SuggestionRequest::GENERATION_WAIT.from_now, updated_at: Time.current) == 1
      update!(last_account_id: request.user.account_id)
      true
    else
      false
    end
  end
end
