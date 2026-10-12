class CreateAccountImportAdmissions < ActiveRecord::Migration[8.2]
  def change
    create_table :account_import_admissions, id: :uuid do |t|
      t.uuid :identity_id, null: false
      t.uuid :account_id
      t.uuid :import_id
      t.bigint :reserved_bytes, null: false, default: 0
      t.datetime :finished_at
      t.timestamps
      t.index [ :identity_id, :created_at ]
      t.index :account_id
      t.index :import_id, unique: true
    end
  end
end
