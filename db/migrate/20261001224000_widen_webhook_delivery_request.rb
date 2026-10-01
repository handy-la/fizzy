class WidenWebhookDeliveryRequest < ActiveRecord::Migration[8.2]
  def change
    # A retry retains the rendered message, including large ActionText bodies.
    change_column :webhook_deliveries, :request, :text, limit: 4_294_967_295
  end
end
