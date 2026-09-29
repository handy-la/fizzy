require "test_helper"

class LeaderboardsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as :kevin
  end

  test "show" do
    columns(:writebook_on_hold).update!(name: "DEPLOYED")
    with_current_user(:kevin) { cards(:logo).triage_into(columns(:writebook_on_hold)) }

    get leaderboard_path

    assert_response :success
    assert_select ".leaderboard__hero-number", text: "1"
    assert_select ".leaderboard__bar-name", text: boards(:writebook).name
  end

  test "the menu links to the leaderboard" do
    get my_menu_path

    assert_select "a[href=?]", leaderboard_path, text: /Leaderboard/
  end
end
