class CreateStorageRepresentationSlots < ActiveRecord::Migration[8.2]
  def change
    create_table :storage_representation_slots, id: :uuid do |t|
      t.uuid :account_id, null: false
      t.integer :position, null: false
      t.datetime :expires_at, null: false
      t.datetime :created_at, null: false
      t.index [ :account_id, :position ], unique: true
    end
  end
end
