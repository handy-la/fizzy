class AddNotifyOnEntryToColumns < ActiveRecord::Migration[8.1]
  def change
    add_column :columns, :notify_on_entry, :boolean, default: true, null: false
  end
end
