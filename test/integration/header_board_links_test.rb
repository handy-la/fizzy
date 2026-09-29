require "test_helper"

# Handy: the header links straight to the user's other boards, so switching
# boards needs no trip through the board menu.
class HeaderBoardLinksTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as :kevin
  end

  test "a board page links to the user's other boards but not to itself" do
    get board_path(boards(:writebook))

    assert_select ".header__board-link[href=?]", board_path(boards(:private)), text: boards(:private).name
    assert_select ".header__board-link[href=?]", board_path(boards(:writebook)), count: 0
  end

  test "a card page links to the other boards, not to the card's own board" do
    get card_path(cards(:logo))

    assert_select ".header__board-link[href=?]", board_path(boards(:private))
    assert_select ".header__board-link[href=?]", board_path(boards(:writebook)), count: 0
  end

  test "a page outside any board links to every board of the user" do
    get root_path

    assert_select ".header__board-link", count: users(:kevin).boards.count
  end

  test "boards the user cannot access are never linked" do
    get root_path

    assert_select ".header__board-link[href=?]", board_path(boards(:miltons_wish_list)), count: 0
  end
end
