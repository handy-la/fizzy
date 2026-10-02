require "test_helper"

class Cards::PublishesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as :kevin
  end

  test "create" do
    card = cards(:logo)
    card.column = nil
    card.drafted!

    assert_changes -> { card.reload.published? }, from: false, to: true do
      post card_publish_path(card)
    end

    assert_redirected_to card.board
    assert_nil card.column
  end

  test "create as JSON" do
    card = cards(:logo)
    card.drafted!

    assert_changes -> { card.reload.published? }, from: false, to: true do
      post card_publish_path(card), as: :json
    end

    assert_response :created
  end

  test "create and add another" do
    card = cards(:logo)
    card.column = nil
    card.drafted!

    assert_changes -> { card.reload.published? }, from: false, to: true do
      assert_difference -> { Card.count }, +1 do
        post card_publish_path(card, creation_type: "add_another")
      end
    end

    new_card = Card.last
    assert new_card.drafted?
    assert_redirected_to card_draft_path(new_card)
    assert_nil card.column
  end

  test "create in To work" do
    card = boards(:writebook).cards.create!(creator: users(:kevin), status: :drafted)
    column = card.board.columns.create!(name: "To work", color: "var(--color-card-2)")

    post card_publish_path(card), params: { column_id: column.id, creation_type: "add" }

    assert_redirected_to card.board
    assert card.reload.published?
    assert_equal column, card.column
    assert_equal({ "column" => "To work" }, card.events.find_by!(action: "card_triaged").api_particulars)
  end

  test "create in To work and add another keeps the destination" do
    card = boards(:writebook).cards.create!(creator: users(:kevin), status: :drafted)
    column = card.board.columns.create!(name: "To work", color: "var(--color-card-2)")

    assert_difference -> { Card.count }, +1 do
      post card_publish_path(card), params: { column_id: column.id, creation_type: "add_another" }
    end

    assert card.reload.published?
    assert_equal column, card.column
    new_card = Card.last
    assert new_card.drafted?
    assert_nil new_card.column
    assert_redirected_to card_draft_path(new_card, column_id: column.id)
    follow_redirect!
    assert_select "input[name=column_id][value='#{column.id}'][checked]"
  end

  test "reject a column outside the card board before publishing" do
    card = boards(:private).cards.create!(creator: users(:kevin), status: :drafted)

    assert_no_changes -> { card.reload.status } do
      assert_no_difference -> { Card.count } do
        post card_publish_path(card), params: { column_id: columns(:writebook_triage).id, creation_type: "add_another" }
      end
    end

    assert_response :not_found
  end
end
