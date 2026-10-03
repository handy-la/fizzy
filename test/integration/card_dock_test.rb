require "test_helper"

# Handy: the floating dock of a card page (Done plus previous and next stage),
# the Done button at the top of the card on a phone, and the toast that offers
# the next card in the source stage.
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

  test "the dock goes back to the board at the far left and goes to the last comment at the far right" do
    get card_path(cards(:logo))

    assert_select ".card-dock > .card-dock__edge--start:first-child a[href=?]", board_path(cards(:logo).board)
    assert_select ".card-dock > .card-dock__edge--end:last-child button[data-action=?]", "card-dock#scrollToLastComment"

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

  test "moving back and moving through the stage selector offer the next source card" do
    post card_triage_path(cards(:logo), column_id: columns(:writebook_in_progress), from: "dock")
    follow_redirect!
    assert_select ".approval-toast a[href=?]", card_path(cards(:layout))

    cards(:logo).update_columns(column_id: @approval.id)
    post card_triage_path(cards(:logo), column_id: columns(:writebook_review))
    follow_redirect!
    assert_select ".approval-toast a[href=?]", card_path(cards(:layout))
  end
  test "moving out of every named column offers the next card in that column" do
    cards(:text).update_columns(column_id: nil)
    cards(:shipping).update_columns(column_id: nil)

    cards(:logo).board.columns.each do |source|
      cards(:logo).update_columns(column_id: source.id)
      cards(:layout).update_columns(column_id: source.id)
      destination = cards(:logo).board.columns.where.not(id: source.id).first

      post card_triage_path(cards(:logo), column_id: destination, from: "dock")
      follow_redirect!

      assert_select ".approval-toast a[href=?]", card_path(cards(:layout))
      assert_select ".approval-toast", text: /#{Regexp.escape(source.name)}/
    end
  end

  test "Done offers an active source card and does not offer the closed card" do
    post card_closure_path(cards(:logo)), as: :turbo_stream
    assert_response :success
    assert_select "turbo-stream[action=update][target=?]", ActionView::RecordIdentifier.dom_id(cards(:logo), :stage_navigation) do
      assert_select ".approval-toast a[href=?]", card_path(cards(:layout))
      assert_select "a[href=?]", card_path(cards(:logo)), count: 0
    end
    assert cards(:logo).reload.closed?
  end

  test "Done reports an empty source column when only closed cards remain" do
    cards(:layout).update_columns(column_id: nil)
    cards(:shipping).update_columns(column_id: @approval.id)

    post card_closure_path(cards(:logo)), as: :turbo_stream

    assert_select ".approval-toast", text: /All caught up/
    assert_select ".approval-toast a", count: 0
  end

  test "moving to Maybe or Not now offers the next source card" do
    delete card_triage_path(cards(:logo), from: "dock")
    follow_redirect!
    assert_select ".approval-toast a[href=?]", card_path(cards(:layout))

    cards(:logo).update_columns(column_id: @approval.id)
    post card_not_now_path(cards(:logo)), as: :turbo_stream
    assert_select ".approval-toast a[href=?]", card_path(cards(:layout))
  end

  test "moving from Maybe offers the next card in Maybe" do
    cards(:logo).update_columns(column_id: nil)
    cards(:layout).update_columns(column_id: nil)
    cards(:layout).gild

    post card_triage_path(cards(:logo), column_id: @approval)
    follow_redirect!

    assert_select ".approval-toast", text: /Maybe\?/
    assert_select ".approval-toast a[href=?]", card_path(cards(:layout))
  end

  test "moving from Not now or Done offers a card from that same special stage" do
    cards(:logo).postpone(user: users(:kevin))
    cards(:layout).postpone(user: users(:kevin))
    post card_triage_path(cards(:logo), column_id: @approval)
    follow_redirect!
    assert_select ".approval-toast", text: /Not now/
    assert_select ".approval-toast a[href=?]", card_path(cards(:layout))

    cards(:logo).close(user: users(:kevin))
    post card_triage_path(cards(:logo), column_id: @approval)
    follow_redirect!
    assert_select ".approval-toast", text: /Done/
    assert_select ".approval-toast a[href=?]", card_path(cards(:shipping))
  end

  test "moving into the same stage does not offer the current card" do
    post card_triage_path(cards(:logo), column_id: @approval)
    follow_redirect!
    assert_select ".approval-toast", count: 0
  end

  test "JSON movement does not leave a navigation notice on a later page" do
    post card_triage_path(cards(:logo), column_id: columns(:writebook_review)), as: :json
    assert_response :no_content
    get card_path(cards(:logo))
    assert_select ".approval-toast", count: 0
  end
end
