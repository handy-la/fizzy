module Storage::AttachmentTracking
  extend ActiveSupport::Concern

  included do
    # Snapshot IDs in before_destroy since parent record may be deleted
    # by the time after_destroy_commit runs
    before_destroy :lock_storage_account, :snapshot_storage_context
    before_create :lock_storage_account
    after_create :record_storage_attach
    after_destroy :record_storage_detach
  end

  private
    def lock_storage_account
      return unless blob

      Account.where(id: blob.account_id).update_all("updated_at = updated_at")
      unless ActiveStorage::Blob.lock.find_by(id: blob_id)
        errors.add(:blob_id, "upload no longer exists")
      end
      throw :abort if errors.any?
    end

    def record_storage_attach
      tracked = storage_tracked_record
      return unless tracked || blob.metadata["quota_upload"]

      Storage::Entry.record \
        account: tracked&.account || blob.account,
        board: tracked&.board_for_storage_tracking,
        recordable: tracked || record,
        blob: blob,
        delta: blob.byte_size,
        operation: "attach"

      Storage::UploadReservation.where(blob_id: blob_id).destroy_all
    end

    def record_storage_detach
      return unless @storage_snapshot

      Storage::Entry.record \
        account: @storage_snapshot[:account],
        board: @storage_snapshot[:board],
        recordable: @storage_snapshot[:recordable],
        blob: blob,
        delta: -blob.byte_size,
        operation: "detach"

      if blob.metadata["quota_upload"] && !blob.attachments.exists?
        Storage::UploadReservation.create_or_find_by!(blob_id: blob_id) do |reservation|
          reservation.account = blob.account
          reservation.identity_id = blob.metadata["quota_identity_id"]
          reservation.byte_size = blob.byte_size
          reservation.expires_at = Time.iso8601(blob.metadata["quota_expires_at"])
        end
      end
    end

    # Snapshot records in before_destroy since parent may be deleted by the time
    # after_destroy_commit runs. The records may be destroyed but .id still works.
    def snapshot_storage_context
      return unless blob

      tracked = storage_tracked_record
      return unless tracked || blob.metadata["quota_upload"]

      @storage_snapshot = {
        account: tracked&.account || blob.account,
        board: tracked&.board_for_storage_tracking,
        recordable: tracked || record
      }
    end

    def storage_tracked_record
      record.try(:storage_tracked_record)
    end
end
