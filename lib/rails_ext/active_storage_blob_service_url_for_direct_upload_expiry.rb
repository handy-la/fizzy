module ActiveStorage
  mattr_accessor :service_urls_for_direct_uploads_expire_in, default: 1.hour
end

module ActiveStorageBlobServiceUrlForDirectUploadExpiry
  # Upload URLs expire separately from download URLs. Pending reservations
  # remain charged until the URL has expired and the cleanup grace has passed.
  def service_url_for_direct_upload(expires_in: ActiveStorage.service_urls_for_direct_uploads_expire_in)
    super
  end
end

ActiveSupport.on_load :active_storage_blob do
  prepend ::ActiveStorageBlobServiceUrlForDirectUploadExpiry
end
