class Account::SignupLock < ApplicationRecord
  SINGLETON_ID = "0000000000000000000000001"

  def self.synchronize
    create_or_find_by!(id: SINGLETON_ID)

    transaction do
      # UPDATE takes a write lock on SQLite and a row lock on MySQL,
      # including when there are no accounts yet.
      where(id: SINGLETON_ID).update_all("value = value + 1")
      yield
    end
  end
end
