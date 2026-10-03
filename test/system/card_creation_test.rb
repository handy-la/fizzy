require "application_system_test_case"

class CardCreationTest < ApplicationSystemTestCase
  test "both creation actions send the selected To work destination" do
    user = users(:kevin)
    board = boards(:writebook)
    column = board.columns.create!(name: "To work", color: "var(--color-card-2)")
    card = board.cards.create!(creator: user, status: :drafted, title: "First card")
    sign_in_as user

    visit card_draft_path(card)
    check "Create in To work"
    click_button "Create and add another"

    assert_no_selector "textarea", text: "First card"
    assert_equal column, card.reload.column
    new_card = Card.order(:id).last
    assert new_card.drafted?
    assert_current_path card_draft_path(new_card, column_id: column.id)
    assert_selector "input[name=column_id]:checked"

    click_button "Create card", exact: true

    assert_current_path board_path(board)
    assert new_card.reload.published?
    assert_equal column, new_card.column
  end

  test "the To work checkbox remembers the last choice in this browser" do
    user = users(:kevin)
    board = boards(:writebook)
    column = board.columns.create!(name: "To work", color: "var(--color-card-2)")
    first = board.cards.create!(creator: user, status: :drafted, title: "First card")
    sign_in_as user

    visit card_draft_path(first)
    assert_no_checked_field "Create in To work"
    check "Create in To work"
    click_button "Create card", exact: true
    assert_current_path board_path(board)
    assert_equal column, first.reload.column

    second = board.cards.create!(creator: user, status: :drafted, title: "Second card")
    visit card_draft_path(second)
    assert_checked_field "Create in To work"
    uncheck "Create in To work"
    click_button "Create card", exact: true
    assert_current_path board_path(board)
    assert_nil second.reload.column

    third = board.cards.create!(creator: user, status: :drafted, title: "Third card")
    visit card_draft_path(third)
    assert_no_checked_field "Create in To work"
  end
end
