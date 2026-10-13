module Account::Storage
  extend ActiveSupport::Concern
  include Storage::Totaled

  included do
    has_many :storage_upload_reservations, class_name: "Storage::UploadReservation", dependent: :destroy
    before_destroy :clear_storage_entries
    after_destroy :clear_storage_entries, :clear_upload_reservations
  end

  def bytes_used
    super + storage_upload_reservations.pending.sum(:byte_size) + Account::Import::Admission.where(account_id: id).sum(:reserved_bytes)
  end

  def bytes_used_exact
    super + storage_upload_reservations.pending.sum(:byte_size) + Account::Import::Admission.where(account_id: id).sum(:reserved_bytes)
  end

  def storage_bytes_allowed
    respond_to?(:storage_limit) ? storage_limit : Storage::UploadReservation::DEFAULT_ACCOUNT_BYTES
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
      attachments = ActiveStorage::Attachment.where(account_id: id).where.not(record_type: Storage::TRACKED_RECORD_TYPES + Storage::DERIVED_RECORD_TYPES)
      reserved_blob_ids = storage_upload_reservations.where(blob_id: attachments.select(:blob_id)).pluck(:blob_id).to_set
      attachments.includes(:blob).find_each.sum do |attachment|
        if attachment.blob.metadata["quota_upload"] || reserved_blob_ids.include?(attachment.blob_id)
          attachment.blob.byte_size
        else
          0
        end
      end
    end
end
