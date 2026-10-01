class CreateCardSuggestionRequests < ActiveRecord::Migration[8.2]
  def change
    create_table :card_suggestion_requests, id: :uuid do |t|
      t.uuid :card_id, null: false
      t.uuid :user_id, null: false
      t.string :kind, null: false
      t.string :token, null: false
      t.string :fingerprint, null: false
      t.string :status, null: false, default: "pending"
      t.text :description, limit: 16.megabytes - 1
      t.text :suggestion
      t.datetime :expires_at, null: false
      t.timestamps
      t.index [ :card_id, :user_id, :kind ], unique: true
    end
  end
end
