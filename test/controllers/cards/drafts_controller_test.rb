require "test_helper"

class Cards::DraftsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as :kevin
  end

  test "show" do
    card = boards(:writebook).cards.create!(creator: users(:kevin), status: :drafted)

    get card_draft_path(card)
    assert_response :success
    assert_select "input[name=column_id]", count: 0
  end

  test "To work choice belongs to the form of both creation buttons" do
    board = boards(:writebook)
    column = board.columns.create!(name: "to work", color: "var(--color-card-2)")
    card = board.cards.create!(creator: users(:kevin), status: :drafted)

    get card_draft_path(card)

    assert_select "form[action='#{card_publish_path(card)}']", count: 1 do
      assert_select "input[type=checkbox][name=column_id][value='#{column.id}']:not([checked])"
      assert_select "button[name=creation_type][value=add]"
      assert_select "button[name=creation_type][value=add_another]"
    end
  end

  test "a column from another board does not select To work" do
    board = boards(:writebook)
    column = board.columns.create!(name: "To work", color: "var(--color-card-2)")
    card = board.cards.create!(creator: users(:kevin), status: :drafted)

    other_column = boards(:private).columns.create!(name: "To work", color: "var(--color-card-2)")
    get card_draft_path(card, column_id: other_column.id)

    assert_select "input[name=column_id][value='#{column.id}']:not([checked])"
  end

  test "show redirects to card when published" do
    card = cards(:logo)

    get card_draft_path(card)
    assert_redirected_to card
  end
end
