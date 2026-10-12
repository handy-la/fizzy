class BoundSuggestionQueue < ActiveRecord::Migration[8.2]
  def change
    create_table :card_suggestion_queues, id: :uuid do |t|
      t.integer :value, null: false, default: 0
      t.uuid :last_account_id
    end

    create_table :card_suggestion_admissions, id: :uuid do |t|
      t.uuid :account_id, null: false
      t.datetime :created_at, null: false
      t.index :created_at
      t.index [ :account_id, :created_at ]
    end

    add_index :card_suggestion_requests, [ :user_id, :status, :expires_at ]
  end
end
