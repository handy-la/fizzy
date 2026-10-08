class CreateStorageUploadReservations < ActiveRecord::Migration[8.2]
  def change
    create_table :storage_upload_reservations, id: :uuid do |t|
      t.uuid :account_id, null: false
      t.uuid :identity_id, null: false
      t.uuid :blob_id, null: false
      t.bigint :byte_size, null: false
      t.datetime :expires_at, null: false
      t.timestamps
      t.index :account_id
      t.index :identity_id
      t.index :blob_id, unique: true
      t.index :expires_at
    end
  end
end
