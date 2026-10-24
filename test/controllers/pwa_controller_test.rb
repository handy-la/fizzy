require "test_helper"

class PwaControllerTest < ActionDispatch::IntegrationTest
  test "service worker is available without a session or account scope" do
    untenanted { get "/service-worker.js" }

    assert_response :success
    assert_equal "text/javascript", response.media_type
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_nil response.headers["X-Fizzy-Offline-Account"]
  end

  test "service worker carries the rendering version, so a new one clears offline pages rendered under the old" do
    untenanted { get "/service-worker.js" }

    assert_response :success
    assert_includes response.body, %(const RENDERING_VERSION = "#{ApplicationController::RENDERING_VERSION}")
    assert_includes response.body, "clearPrivateCaches().then(() => self.clients.claim())"
    assert_not_includes response.body, "TurboOffline.start()"
  end
end
