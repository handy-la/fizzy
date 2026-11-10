require "test_helper"

class ControllerAuthenticationTest < ActionDispatch::IntegrationTest
  test "access without an account slug redirects to menu" do
    sign_in_as :kevin
    integration_session.default_url_options = integration_session.default_url_options.merge(script_name: "") # no tenant

    get cards_path

    assert_redirected_to session_menu_path
  end

  test "access with an account slug but no session redirects to new session" do
    get cards_path

    assert_redirected_to new_session_path(script_name: nil)
  end

  # Handy #2208. A page whose session was revoked submits the time zone form by
  # itself (PUT /my/timezone). Only a GET for HTML can be replayed after login:
  # the redirect after login is a GET, and My::TimezonesController has no show.
  # A regression that stores request.url for every method fails this test.
  # No route helper is called before sign_in_as: one with script_name: nil
  # changes the integration session's URL options and the login fails.
  test "a PUT without a session does not become the return URL after login" do
    put my_timezone_path, params: { timezone_name: "America/Mexico_City" }
    assert_response :redirect
    assert_nil session[:return_to_after_authenticating]

    sign_in_as :kevin

    untenanted { assert_redirected_to landing_url }
  end

  test "a JSON GET without a session does not become the return URL" do
    get boards_path(format: :json)

    assert_redirected_to new_session_path(script_name: nil)
    assert_nil session[:return_to_after_authenticating]
  end

  test "an HTML GET without a session returns to its URL after login" do
    get cards_path

    sign_in_as :kevin

    assert_redirected_to cards_url
  end

  test "access with an account slug and a session allows functional access" do
    sign_in_as :kevin

    get cards_path

    assert_response :success
  end
end
