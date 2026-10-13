# One of the few processings of a representation an account may run at once (Handy #968). The unique
# index on (account_id, position) is what makes a slot exclusive: an INSERT either takes the position
# or raises, on MySQL and SQLite alike. Release deletes by id, so it can only ever remove its own row.
# A row left by a dead process is taken over once it expires. Writes go through ApplicationRecord, the
# class that sets up the connections: a GET may run on the replica, and connected_to refuses a concrete model.
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

  def release
    ApplicationRecord.with_writing_role { self.class.where(id: id).delete_all }
  end
end
