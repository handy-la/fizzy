# One of the few processings of a representation an account may run at once (Handy #968). The unique
# index on (account_id, position) is what makes a slot exclusive: an INSERT either takes the position
# or raises, on MySQL and SQLite alike. Release deletes by id, so it can only ever remove its own row.
# While its holder works, #hold renews the slot, so only a slot whose process died is taken over once
# it expires. Writes go through ApplicationRecord, the class that sets up the connections: a GET may run
# on the replica, and connected_to refuses a concrete model.
class Storage::RepresentationSlot < ApplicationRecord
  def self.acquire(account_id, positions:, expires_in:)
    ApplicationRecord.with_writing_role do
      where(account_id: account_id, expires_at: ..Time.current).delete_all

      positions.times do |position|
        return create!(account_id: account_id, position: position, expires_at: expires_in.from_now)
      rescue ActiveRecord::RecordNotUnique
        next
      end

      nil
    end
  end

  # Renews the slot every +renew_every+ on a thread of its own while the block runs: a processing may
  # take longer than +expires_in+ (a slow download, a preview and then its variant), and an expired slot
  # would let another request take its position while this one still works.
  def hold(expires_in:, renew_every:)
    stop = Thread::Queue.new
    heartbeat = Thread.new do
      while stop.pop(timeout: renew_every).nil?
        renew(expires_in: expires_in)
      end
    end

    yield
  ensure
    stop&.push(true)
    heartbeat&.join
  end

  def renew(expires_in:)
    ApplicationRecord.with_writing_role do
      self.class.connection_pool.with_connection do
        self.class.where(id: id).update_all(expires_at: expires_in.from_now)
      end
    end
  rescue => error
    Rails.error.report error, handled: true
  end

  def release
    ApplicationRecord.with_writing_role { self.class.where(id: id).delete_all }
  end
end
