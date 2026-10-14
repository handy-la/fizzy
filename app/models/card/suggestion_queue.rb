class Card::SuggestionQueue < ApplicationRecord
  SINGLETON_ID = "0000000000000000000000001"
  USER_LIMIT = 1
  ACCOUNT_LIMIT = 2
  GLOBAL_LIMIT = 4
  ACCOUNT_BUDGET = 10
  GLOBAL_BUDGET = 30
  BUDGET_WINDOW = 1.hour

  class Full < StandardError
    attr_reader :retry_after

    def initialize(retry_after = nil)
      @retry_after = retry_after
      super()
    end
  end

  # A single-tenant installation has one account: its budget is the global one.
  def self.account_budget
    configured_budget("AI_SUGGESTION_ACCOUNT_BUDGET") || (Account.multi_tenant ? ACCOUNT_BUDGET : global_budget)
  end

  def self.global_budget
    configured_budget("AI_SUGGESTION_GLOBAL_BUDGET") || GLOBAL_BUDGET
  end

  def self.configured_budget(name)
    budget = Integer(ENV[name].to_s, 10, exception: false)
    budget if budget&.positive?
  end
  private_class_method :configured_budget

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
    account = admissions.where(account_id: user.account_id)
    exhausted = account.count >= self.class.account_budget ? account : (admissions if admissions.count >= self.class.global_budget)
    raise Full.new(budget_retry_after(exhausted)) if exhausted

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

  private
    def budget_retry_after(admissions)
      [ (admissions.minimum(:created_at) + BUDGET_WINDOW - Time.current).ceil, 1 ].max
    end
end
