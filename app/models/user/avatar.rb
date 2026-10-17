require "zlib"

module User::Avatar
  extend ActiveSupport::Concern

  ALLOWED_AVATAR_CONTENT_TYPES = %w[ image/jpeg image/png image/gif image/webp ].freeze
  MAX_AVATAR_BYTES = 10.megabytes
  MAX_AVATAR_DIMENSIONS = { width: 4096, height: 4096 }.freeze
  AVATAR_COLORS = %w[
    #AF2E1B #CC6324 #3B4B59 #BFA07A #ED8008 #ED3F1C #BF1B1B #736B1E #D07B53
    #736356 #AD1D1D #BF7C2A #C09C6F #698F9C #7C956B #5D618F #3B3633 #67695E
  ].freeze

  included do
    # Prepended so it runs before has_one_attached analyzes the upload in its
    # own before_validation.
    before_validation :reject_oversized_avatar, prepend: true

    has_one_attached :avatar, dependent: :purge_later do |attachable|
      attachable.variant :thumb, resize_to_fill: [ 256, 256 ], process: :immediately
    end

    before_save :start_avatar_storage_mutation, if: :avatar_upload_pending?

    scope :with_avatars, -> { preload(:account, :avatar_attachment) }

    validate :avatar_content_type_allowed, :avatar_dimensions_allowed, if: :avatar_attached?
  end

  # The attachment and its ledger entry are created in has_one_attached's
  # after_save. The mutation wraps the whole save, so the limit is verified
  # once every callback has run, inside the same transaction.
  def save(**options, &block)
    with_avatar_storage_limit { super(**options, &block) }
  end

  def save!(**options, &block)
    with_avatar_storage_limit { super(**options, &block) }
  end

  def avatar_attached?
    avatar.attached?
  end

  def avatar_thumbnail
    avatar.variable? ? avatar.variant(:thumb) : avatar
  end

  def avatar_background_color
    AVATAR_COLORS[Zlib.crc32(to_param) % AVATAR_COLORS.size]
  end

  # Avatars are always publicly accessible
  def publicly_accessible?
    true
  end

  private
    def avatar_upload_pending?
      attachment_changes["avatar"].is_a?(ActiveStorage::Attached::Changes::CreateOne)
    end

    def reject_oversized_avatar
      if avatar_upload_pending? && attachment_changes["avatar"].blob.byte_size > MAX_AVATAR_BYTES
        errors.add(:avatar, "must be smaller than #{MAX_AVATAR_BYTES / 1.megabyte} MB")
        throw :abort
      end
    end

    def with_avatar_storage_limit(&block)
      if avatar_upload_pending?
        self.class.transaction { Storage::Mutation.wrap(account, &block) }
      else
        yield
      end
    end

    # A user is not a tracked record, so Storage::AttachmentTracking charges
    # the avatar only when its blob is marked as a quota upload. The mutation
    # locks the account before reading its usage; it raises
    # Storage::QuotaExceeded when the new avatar grows usage past the limit.
    def start_avatar_storage_mutation
      blob = attachment_changes["avatar"].blob
      blob.metadata = blob.metadata.merge("quota_upload" => true) if blob.new_record?
      Storage::Mutation.for(account).start
    end

    def avatar_content_type_allowed
      unless ALLOWED_AVATAR_CONTENT_TYPES.include?(avatar.content_type)
        errors.add(:avatar, "must be a JPEG, PNG, GIF, or WebP image")
      end
    end

    def avatar_dimensions_allowed
      return unless avatar.blob.analyzed? || avatar.blob.analyze

      width = avatar.blob.metadata[:width]
      height = avatar.blob.metadata[:height]

      if width && width > MAX_AVATAR_DIMENSIONS[:width]
        errors.add(:avatar, "width must be less than #{MAX_AVATAR_DIMENSIONS[:width]}px")
      end

      if height && height > MAX_AVATAR_DIMENSIONS[:height]
        errors.add(:avatar, "height must be less than #{MAX_AVATAR_DIMENSIONS[:height]}px")
      end
    end
end
