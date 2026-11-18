class CreateTickHealths < ActiveRecord::Migration[8.2]
  def change
    create_table :tick_healths, id: :uuid do |t|
      t.uuid :account_id, null: false
      t.uuid :board_id, null: false
      t.string :product_id, limit: 100, null: false
      t.string :stage_id, limit: 100, null: false
      t.bigint :revision, null: false, default: 0
      t.string :request_digest, limit: 64, null: false
      t.text :evidence, null: false
      t.timestamps
      t.index [ :board_id, :stage_id ], unique: true
      t.index :account_id
    end
  end
end
