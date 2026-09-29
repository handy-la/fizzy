require "test_helper"

# Handy: the floating dock of a card page (Done plus previous and next stage),
# the Done button at the top of the card on a phone, and the toast that offers
# the next card awaiting approval.
class CardDockTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as :kevin

    @approval = columns(:writebook_on_hold)
    @approval.update!(name: "AWAITING APPROVAL")
    cards(:logo).update_columns(column_id: @approval.id)
    cards(:layout).update_columns(column_id: @approval.id)
  end

  test "the dock moves the card to the previous and next stage of the board" do
    get card_path(cards(:logo))

    assert_select ".card-dock" do
      assert_select "form[action=?]", card_triage_path(cards(:logo), column_id: columns(:writebook_in_progress), from: "dock")
      assert_select "form[action=?]", card_triage_path(cards(:logo), column_id: columns(:writebook_review), from: "dock")
      assert_select "form[action=?]", card_closure_path(cards(:logo))
      assert_select ".card-dock__arc-text", text: "In progress"
      assert_select ".card-dock__arc-text", text: "Review"
    end
  end

  test "the dock goes back to the board at the far left and scrolls to the bottom at the far right" do
    get card_path(cards(:logo))

    assert_select ".card-dock > .card-dock__edge--start:first-child a[href=?]", board_path(cards(:logo).board)
    assert_select ".card-dock > .card-dock__edge--end:last-child button[data-action=?]", "card-dock#scrollToBottom"

    get card_path(cards(:shipping))
    assert_select ".card-dock .card-dock__edge", count: 2
  end

  test "the first column steps back to Maybe? and a card in Maybe? steps into the first column" do
    get card_path(cards(:text).tap { it.update_columns(column_id: columns(:writebook_triage).id) })
    assert_select ".card-dock form[action=?]", card_triage_path(cards(:text), from: "dock")

    get card_path(cards(:text).tap { it.update_columns(column_id: nil) })
    assert_select ".card-dock__stage--previous form", count: 0
    assert_select ".card-dock form[action=?]", card_triage_path(cards(:text), column_id: columns(:writebook_triage), from: "dock")
  end

  test "a closed card's dock only undoes Done" do
    get card_path(cards(:shipping))

    assert_select ".card-dock" do
      assert_select ".card-dock__button--closed"
      assert_select ".card-dock__stage form", count: 0
    end
  end

  test "an open card has a Done button at the top of the card, a closed card does not" do
    get card_path(cards(:logo))
    assert_select ".card__header form.card__quick-done-form[action=?]", card_closure_path(cards(:logo))

    get card_path(cards(:shipping))
    assert_select ".card__quick-done-form", count: 0
  end

  test "moving forward out of AWAITING APPROVAL from the dock offers the next card waiting" do
    post card_triage_path(cards(:logo), column_id: columns(:writebook_review), from: "dock")
    follow_redirect!

    assert_select ".approval-toast a[href=?]", card_path(cards(:layout)), text: /Continue/
  end

  test "the toast says so when no card is left awaiting approval" do
    cards(:layout).update_columns(column_id: columns(:writebook_triage).id)

    post card_triage_path(cards(:logo), column_id: columns(:writebook_review), from: "dock")
    follow_redirect!

    assert_select ".approval-toast", text: /All caught up/
  end

  test "no toast when moving back, or when the move did not come from the dock" do
    post card_triage_path(cards(:logo), column_id: columns(:writebook_in_progress), from: "dock")
    follow_redirect!
    assert_select ".approval-toast", count: 0

    cards(:logo).update_columns(column_id: @approval.id)
    post card_triage_path(cards(:logo), column_id: columns(:writebook_review))
    follow_redirect!
    assert_select ".approval-toast", count: 0
  end
end
