class BindPushSubscriptionsToSessions < ActiveRecord::Migration[8.2]
  def change
    # Existing registrations have no proof of which browser session consented.
    # Require a new explicit subscription instead of guessing their owner.
    reversible do |direction|
      direction.up { execute "DELETE FROM push_subscriptions" }
    end

    add_reference :push_subscriptions, :session, type: :uuid
    add_column :push_subscriptions, :endpoint_digest, :string, limit: 64, null: false
    add_index :push_subscriptions, :endpoint_digest, unique: true
  end
end
