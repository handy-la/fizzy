module Account::Storage
  extend ActiveSupport::Concern
  include Storage::Totaled

  included do
    has_many :storage_upload_reservations, class_name: "Storage::UploadReservation", dependent: :destroy
    before_destroy :clear_storage_entries
    after_destroy :clear_storage_entries, :clear_upload_reservations
  end

  def bytes_used
    super + storage_upload_reservations.sum(:byte_size)
  end

  def bytes_used_exact
    super + storage_upload_reservations.sum(:byte_size)
  end

  private
    def clear_storage_entries
      Storage::Entry.where(account_id: id).delete_all
    end

    def clear_upload_reservations
      Storage::UploadReservation.where(account_id: id).delete_all
    end

    def calculate_real_storage_bytes
      boards.sum { |board| board.send(:calculate_real_storage_bytes) } + untracked_direct_upload_bytes
    end

    def untracked_direct_upload_bytes
      ActiveStorage::Attachment.where(account_id: id).where.not(record_type: Storage::TRACKED_RECORD_TYPES)
        .includes(:blob).find_each.sum { |attachment| attachment.blob.metadata["quota_upload"] ? attachment.blob.byte_size : 0 }
    end
end
