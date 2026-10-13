# Raised when a mutation would grow the account's usage past its storage limit.
# It rolls back the whole save, ledger entries included.
class Storage::QuotaExceeded < ActiveRecord::RecordNotSaved
  def initialize(record = nil)
    super("Storage limit exceeded", record)
  end
end
