class ApplicationController < ActionController::Base
  include OfflineCaching
  include Authentication
  include Authorization
  include BlockSearchEngineIndexing
  include CurrentRequest, CurrentTimezone, SetPlatform
  include RequestForgeryProtection
  include TurboFlash, ViewTransitions
  include RoutingHeaders

  etag { "v1" }
  stale_when_importmap_changes

  rescue_from Storage::QuotaExceeded, with: -> { head :forbidden }
  allow_browser versions: :modern
end
