module OfflineCaching
  extend ActiveSupport::Concern

  included do
    prepend_before_action :prevent_sensitive_response_storage
    after_action :identify_offline_response
  end

  private
    def prevent_sensitive_response_storage
      response.cache_control[:no_store] = true unless offline_page_request? || http_cached_resource_request?
    end

    def offline_page_request?
      request.get? && request.format.html? && request.headers["Turbo-Frame"].blank? &&
        controller_path.in?(%w[ boards cards ]) && action_name.in?(%w[ index show ])
    end

    def http_cached_resource_request?
      # Preserve existing HTTP caching for avatars and public native configuration.
      # Neither resource receives permission to enter the private offline cache.
      request.get? && action_name == "show" && controller_path.in?(%w[ users/avatars client_configurations ])
    end

    def identify_offline_response
      return if http_cached_resource_request?

      unless (offline_page_request? && response.successful?) || http_cached_resource_request?
        response.cache_control[:no_store] = true
      end

      response.headers["X-Fizzy-Offline-Session"] = if Current.session&.persisted?
        Digest::SHA256.hexdigest("#{Current.identity.id}:#{Current.session.id}")
      else
        "none"
      end

      if offline_page_request? && response.successful? && Current.user&.active? && Current.account&.active?
        response.headers["X-Fizzy-Offline-Account"] = Current.account.external_account_id.to_s
      end
    end

    def clear_offline_cache
      response.headers["X-Fizzy-Clear-Offline-Cache"] = "true"
      response.headers["Clear-Site-Data"] = '"cache"'
      response.cache_control[:no_store] = true
    end
end
