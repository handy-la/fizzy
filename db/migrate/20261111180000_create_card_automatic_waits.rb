# Automatic waits that an external producer (Dédalo's CI queue or a registered
# monitor) declares on a card, and the per-card fence that retires every earlier
# declaration when the card closes, reopens or changes board. Rows are never
# deleted by a clear: the tombstone keeps the run and the revision, so a retired
# run cannot claim the wait again. Contract: docs/automatic-waits.md.
class CreateCardAutomaticWaits < ActiveRecord::Migration[8.2]
  def change
    create_table :card_automatic_wait_fences, id: :uuid do |t|
      t.uuid :account_id, null: false
      t.uuid :card_id, null: false
      t.bigint :epoch, null: false, default: 0
      t.string :reason, limit: 32
      t.timestamps

      t.index :account_id
      t.index :card_id, unique: true
    end

    create_table :card_automatic_waits, id: :uuid do |t|
      t.uuid :account_id, null: false
      t.uuid :card_id, null: false
      t.uuid :board_id, null: false
      t.uuid :declared_by_id

      t.string :key, null: false, limit: 64
      t.string :producer, null: false, limit: 16
      t.string :state, null: false, limit: 16
      t.string :owner, null: false, limit: 100
      t.string :run_id, null: false, limit: 100
      t.bigint :run_sequence, null: false
      t.string :reason, null: false, limit: 200
      t.string :expected_event, null: false, limit: 200
      t.datetime :next_check_at
      t.datetime :valid_until, null: false
      t.string :human_condition, null: false, limit: 16
      t.bigint :epoch, null: false
      t.bigint :revision, null: false, default: 1
      t.string :request_digest, null: false, limit: 64

      t.datetime :retired_at
      t.string :retired_reason, limit: 32

      t.timestamps

      t.index :account_id
      t.index [ :card_id, :key ], unique: true
      t.index [ :card_id, :retired_at ]
    end
  end
end
