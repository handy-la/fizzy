require "test_helper"

# Handy #2304. Contract, regression, coverage and seam: docs/test-audits/handy-2304.md.
class Boards::PowerThroughsControllerTest < ActionDispatch::IntegrationTest
  MARKER = Card::PendingRequest::MARKER

  setup do
    sign_in_as :david
    @board = boards(:writebook)
    Comment.where(card: @board.cards).destroy_all
    cards(:text).comments.create!(body: "❓ ¿Uno o dos?#{MARKER}", creator: users(:jz))
  end

  test "entering without a card pins the first card that waits in the URL" do
    get board_power_through_path(@board)

    assert_redirected_to board_power_through_path(@board, card: cards(:text).number)
  end

  test "shows the focused card that waits, with its request" do
    get board_power_through_path(@board, card: cards(:text).number)

    assert_response :success
    assert_select ".power-through__title", text: /#3\s+The text is too small/
    assert_select ".power-through__request", text: /¿Uno o dos\?/
    assert_select "form[action=?]", card_comments_path(cards(:text))
  end

  test "reading the page writes nothing" do
    assert_no_difference -> { Comment.count + Event.count } do
      get board_power_through_path(@board, card: cards(:text).number)
    end
  end

  test "a card that no longer waits stays in focus with a notice" do
    get board_power_through_path(@board, card: cards(:logo).number)

    assert_select ".power-through__title", text: /#1/
    assert_select ".power-through__notice", text: /ya no espera una respuesta/
  end

  test "an empty queue says so" do
    get board_power_through_path(@board, stages: columns(:writebook_on_hold).id)

    assert_select ".power-through__empty"
  end

  test "a board without access is not found" do
    get board_power_through_path(boards(:private))

    assert_response :not_found
  end

  test "the card state answers the current verdict and fingerprint" do
    get board_power_through_card_path(@board, cards(:text).number, format: :json)

    assert_response :success
    assert_equal "pending", @response.parsed_body["status"]
    assert_equal Card::PendingRequest.for(cards(:text)).fingerprint, @response.parsed_body["fingerprint"]
  end

  test "the card state of a card outside the board is not found" do
    get board_power_through_card_path(@board, cards(:radio).number + 100, format: :json)

    assert_response :not_found
  end
end
