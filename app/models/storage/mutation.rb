# Measures the account usage across one save of a tracked record, so the limit
# sees the net delta of every attachment that save creates or removes. Rails
# runs those changes in different callbacks (the rich text in after_update,
# a has_one_attached removal in after_save), so a check on one attachment
# alone can count a removal that has not happened yet.
class Storage::Mutation
  thread_mattr_accessor :current

  attr_reader :account

  # Joins an open mutation for the same account; otherwise opens one that is
  # verified when the block returns. Call it inside the save's transaction.
  def self.wrap(account, &block)
    if account.nil? || self.for(account)
      yield
    else
      open(account, &block)
    end
  end

  def self.open(account)
    previous, self.current = current, new(account)
    yield.tap { current.verify! }
  ensure
    self.current = previous
  end

  def self.for(account)
    current if current&.account&.id == account.id
  end

  def initialize(account)
    @account = account
  end

  # Called before the first attachment change: lock the account, then read.
  def start
    @baseline ||= begin
      Account.where(id: account.id).update_all("updated_at = updated_at")
      account.bytes_used_exact
    end
  end

  # Usage includes ledger entries and pending upload reservations, so a
  # reserved blob that is attached moves its charge and adds nothing. Only a
  # mutation that grows usage past the limit is refused.
  def verify!
    return unless @baseline

    usage = account.bytes_used_exact
    raise Storage::QuotaExceeded if usage > @baseline && usage > account.storage_bytes_allowed
  end
end
