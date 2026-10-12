class Export < ApplicationRecord
  CURRENT_LIMIT = 10
  IN_PROGRESS_LIMIT = 10

  class LimitExceeded < StandardError; end

  belongs_to :account
  belongs_to :user

  has_one_attached :file, dependent: :purge_later

  enum :status, %w[ pending processing completed failed ].index_by(&:itself), default: :pending

  scope :current, -> { where(created_at: 24.hours.ago..) }
  scope :in_progress, -> { where(status: %w[ pending processing ]) }
  scope :expired, -> { where(completed_at: ...24.hours.ago) }

  def self.start_for(principal, **attributes)
    transaction do
      # UPDATE locks the principal before quota reads on SQLite and MySQL.
      principal.class.where(id: principal.id).update_all("updated_at = updated_at")
      exports = where(principal.model_name.element => principal)
      if exports.current.count >= CURRENT_LIMIT || exports.in_progress.count >= IN_PROGRESS_LIMIT
        raise LimitExceeded
      end

      exports.create!(**attributes)
    end
  end

  def self.cleanup
    expired.destroy_all
  end

  def build_later
    DataExportJob.perform_later(self)
  end

  def build
    processing!

    with_context do
      ZipFile.create_for(file, filename: filename) do |zip|
        populate_zip(zip)
      end
      mark_completed
      ExportMailer.completed(self).deliver_later
    end
  rescue => e
    update!(status: :failed)
    raise e
  end

  def mark_completed
    update!(status: :completed, completed_at: Time.current)
  end

  def accessible_to?(accessor)
    accessor == user
  end

  private
    def filename
      "fizzy-export-#{id}.zip"
    end

    def with_context
      Current.set(account: account) do
        old_url_options = ActiveStorage::Current.url_options
        ActiveStorage::Current.url_options = Rails.application.routes.default_url_options

        yield
      ensure
        ActiveStorage::Current.url_options = old_url_options
      end
    end

    def populate_zip(zip)
      raise NotImplementedError, "Subclasses must implement populate_zip"
    end
end
