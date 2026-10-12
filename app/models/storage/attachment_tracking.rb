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
      return if derived_storage_attachment?

      tracked = storage_tracked_record
      return unless tracked || storage_reserved_blob?

      Storage::Entry.record \
        account: tracked&.account || blob.account,
        board: tracked&.board_for_storage_tracking,
        recordable: tracked || record,
        blob: blob,
        delta: blob.byte_size,
        operation: "attach"
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

      if !blob.attachments.exists? && (reservation = Storage::UploadReservation.find_by(blob_id: blob_id, account_id: blob.account_id))
        # Keep the server-issued identity, size and creation time. Metadata
        # from an imported blob can never create or renew a reservation.
        reservation.update!(expires_at: reservation.upload_url_expires_at)
      end
    end

    # Snapshot records in before_destroy since parent may be deleted by the time
    # after_destroy_commit runs. The records may be destroyed but .id still works.
    def snapshot_storage_context
      return unless blob
      return if derived_storage_attachment?

      tracked = storage_tracked_record
      return unless tracked || storage_reserved_blob?

      @storage_snapshot = {
        account: tracked&.account || blob.account,
        board: tracked&.board_for_storage_tracking,
        recordable: tracked || record
      }
    end

    def storage_reserved_blob?
      blob.metadata["quota_upload"] || Storage::UploadReservation.exists?(account_id: blob.account_id, blob_id: blob_id)
    end

    def derived_storage_attachment?
      record_type.in?(Storage::DERIVED_RECORD_TYPES)
    end

    def storage_tracked_record
      record.try(:storage_tracked_record)
    end
end
