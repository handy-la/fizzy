class CreateActionPackPasskeyConsumedChallenges < ActiveRecord::Migration[8.2]
  def change
    create_table :action_pack_passkey_consumed_challenges, id: :uuid do |t|
      t.string :digest, null: false
      t.datetime :expires_at

      t.datetime :created_at, null: false

      t.index :digest, unique: true
      t.index :expires_at
    end
  end
end
