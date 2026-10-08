class CreateAccountSignupLocks < ActiveRecord::Migration[8.2]
  def change
    create_table :account_signup_locks, id: :uuid do |t|
      t.bigint :value, default: 0, null: false
    end
  end
end
