require "application_system_test_case"

# Handy: the card dock follows the scroll once the card's header leaves the
# screen, even while the rest of a long card is still in view.
class CardDockSystemTest < ApplicationSystemTestCase
  setup do
    sign_in_as(users(:david))
    @card = cards(:layout)
    @card.update!(description: Array.new(80) { |line| "Line #{line} of a long description." }.join("\n\n"))
  end

  test "the dock appears when the header scrolls off and hides when it comes back" do
    visit card_url(@card)
    assert_selector ".card__header"
    assert_no_selector ".card-dock--visible"

    page.execute_script(<<~JS)
      const header = document.querySelector(".card__header").getBoundingClientRect()
      window.scrollBy(0, header.bottom + 20)
    JS

    assert_selector ".card-dock--visible", wait: 5
    assert page.evaluate_script(%(document.querySelector(".card-perma__bg").getBoundingClientRect().bottom > 0)),
      "the card body should still be on screen"

    page.execute_script("window.scrollTo(0, 0)")
    assert_no_selector ".card-dock--visible", wait: 5
  end

  test "Done from the dock turns its button into the done state and keeps the dock in view" do
    visit card_url(@card)
    page.execute_script(%(window.scrollBy(0, document.querySelector(".card__header").getBoundingClientRect().bottom + 20)))
    assert_selector ".card-dock--visible", wait: 5

    within(".card-dock") { click_on "Mark as Done" }

    assert_selector ".card-dock--visible .card-dock__button--closed", wait: 5
    assert @card.reload.closed?
  end

  test "the dock scrolls to the bottom of the page and goes back to the board" do
    visit card_url(@card)
    page.execute_script(%(window.scrollBy(0, document.querySelector(".card__header").getBoundingClientRect().bottom + 20)))
    assert_selector ".card-dock--visible", wait: 5

    within(".card-dock") { click_on "Scroll to bottom" }
    assert_selector ".card-dock--visible", wait: 5
    Timeout.timeout(5) do
      sleep 0.1 until page.evaluate_script("Math.ceil(window.scrollY + window.innerHeight) >= document.documentElement.scrollHeight")
    end

    within(".card-dock") { click_on "Back to #{@card.board.name}" }
    assert_current_path board_path(@card.board)
  end
end
