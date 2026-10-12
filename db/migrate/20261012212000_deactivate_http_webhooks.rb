class DeactivateHttpWebhooks < ActiveRecord::Migration[8.2]
  def up
    execute "UPDATE webhooks SET active = FALSE WHERE LOWER(TRIM(url)) LIKE 'http:%'"
  end

  def down
    # Do not reactivate a destination that sends private events without TLS.
  end
end
