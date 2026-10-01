class TrackSuggestionRequestLifecycle < ActiveRecord::Migration[8.2]
  def change
    add_column :card_suggestion_requests, :requested_at, :datetime
    add_column :card_suggestion_requests, :started_at, :datetime
    add_column :card_suggestion_requests, :finished_at, :datetime
    add_column :card_suggestion_requests, :error_category, :string
    add_index :card_suggestion_requests, [ :status, :expires_at ]
  end
end
