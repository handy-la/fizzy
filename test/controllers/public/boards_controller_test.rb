require "test_helper"

class Public::BoardsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as :kevin

    boards(:writebook).publish
  end

  test "show" do
    get published_board_path(boards(:writebook))
    assert_response :success
  end

  test "not found if the board is not published" do
    key = boards(:writebook).publication.key

    boards(:writebook).unpublish
    get public_board_path(key)

    assert_response :not_found
  end

  test "show excludes draft cards from closed count" do
    draft_card = cards(:buy_domain)
    draft_card.update!(status: :drafted)
    Current.set(user: users(:david)) { draft_card.close }

    get published_board_path(boards(:writebook))
    assert_response :success
    assert_select ".cards--closed .cards__expander-count", "1"
  end

  test "show works without authentication" do
    sign_out
    get published_board_path(boards(:writebook))
    assert_response :success
  end

  # Upstream caches this page publicly for 30 seconds when nobody is signed in. The fork's
  # OfflineCaching marks every page outside its offline list no-store (Handy 925), so no
  # cache keeps it, signed in or not.
  test "show is not stored in any cache without authentication" do
    sign_out
    get published_board_path(boards(:writebook))

    assert_not response.cache_control[:public]
    assert response.cache_control[:no_store]
  end

  test "show is not publicly cacheable when signed in" do
    get published_board_path(boards(:writebook))

    assert_not response.cache_control[:public]
    assert response.cache_control[:no_store]
  end
end
