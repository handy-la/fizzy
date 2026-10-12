class AddClientIdToPushSubscriptions < ActiveRecord::Migration[8.2]
  def change
    add_column :push_subscriptions, :client_id, :string, limit: 64
  end
end
