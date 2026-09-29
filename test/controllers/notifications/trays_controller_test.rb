require "test_helper"

class Notifications::TraysControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as :kevin
  end

  test "show" do
    get tray_notifications_path

    assert_response :success
    assert_select "div", text: /Layout is broken/
  end

  test "each notification wears the color of its card's column" do
    get tray_notifications_path

    notification = notifications(:logo_assignment_kevin)
    assert_select "##{dom_id(notification)} a.card--notification[style*=?]", "--card-color: #{cards(:logo).color}"
  end

  test "a cached notification follows its card to a new column" do
    with_actionview_partial_caching do
      get tray_notifications_path
      with_current_user(:kevin) { cards(:logo).triage_into(columns(:writebook_in_progress)) }

      get tray_notifications_path
    end

    notification = notifications(:logo_assignment_kevin)
    assert_select "##{dom_id(notification)} a.card--notification[style*=?]", "--card-color: #{columns(:writebook_in_progress).color}"
  end

  test "show as JSON" do
    expected_ids = users(:kevin).notifications.unread.ordered.limit(100).pluck(:id)

    get tray_notifications_path(format: :json)

    assert_response :success
    assert_equal expected_ids, @response.parsed_body.map { |s| s["id"] }
  end

  test "show as JSON with include_read includes read notifications" do
    notifications = users(:kevin).notifications
    expected_ids = notifications.unread.ordered.limit(100).pluck(:id) +
      notifications.read.ordered.limit(100).pluck(:id)

    get tray_notifications_path(format: :json, include_read: true)

    assert_response :success
    assert_equal expected_ids, @response.parsed_body.map { |s| s["id"] }
  end
end
