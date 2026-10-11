require "test_helper"

class PwaControllerTest < ActionDispatch::IntegrationTest
  test "service worker is available without a session or account scope" do
    untenanted { get "/service-worker.js" }

    assert_response :success
    assert_equal "text/javascript", response.media_type
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_nil response.headers["X-Fizzy-Offline-Account"]
  end
end
