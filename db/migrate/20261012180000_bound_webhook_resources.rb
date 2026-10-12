class BoundWebhookResources < ActiveRecord::Migration[8.2]
  def change
    create_table :webhook_dispatches, id: :uuid do |t|
      t.integer :value, null: false, default: 0
      t.uuid :last_account_id
      t.string :token
      t.datetime :leased_until
      t.boolean :running, null: false, default: false
    end

    create_table :webhook_creations, id: :uuid do |t|
      t.uuid :account_id, null: false
      t.datetime :created_at, null: false
      t.index :created_at
      t.index [ :account_id, :created_at ]
    end

    create_table :webhook_retries, id: :uuid do |t|
      t.uuid :account_id, null: false
      t.datetime :created_at, null: false
      t.index :created_at
      t.index [ :account_id, :created_at ]
    end

    add_index :webhook_deliveries, [ :account_id, :state, :created_at ]
  end
end
