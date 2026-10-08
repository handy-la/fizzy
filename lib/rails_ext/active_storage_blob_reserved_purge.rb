module ActiveStorageBlobReservedPurge
  def purge
    if reservation = Storage::UploadReservation.find_by(blob_id: id)
      if Time.current < reservation.expires_at + Storage::UploadReservation::PURGE_GRACE
        # A signed S3 PUT can recreate an object after deletion. Keep its key
        # and quota until the upload URL can no longer be used.
        ActiveStorage::PurgeJob.set(wait_until: reservation.expires_at + Storage::UploadReservation::PURGE_GRACE).perform_later(self)
      else
        reservation.purge
      end
    else
      super
    end
  end
end

ActiveSupport.on_load :active_storage_blob do
  prepend ActiveStorageBlobReservedPurge
end
