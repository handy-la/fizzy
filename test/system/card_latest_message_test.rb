require "application_system_test_case"

# Handy #1265: a card opens on the start of its latest message, below the title bar,
# so nobody has to scroll down to read it.
class CardLatestMessageTest < ApplicationSystemTestCase
  setup do
    sign_in_as(users(:david))
    @card = cards(:layout)
    @card.update!(description: Array.new(60) { |line| "<p>Line #{line} of a long description.</p>" }.join)
    @older = @card.comments.create!(creator: users(:kevin), body: "<p>An older message.</p>" * 30)
    @latest = @card.comments.create!(creator: users(:david),
      body: Array.new(40) { |line| "Line #{line} of the latest message." }.join("<br>"))
  end

  [ [ 1280, 800 ], [ 390, 844 ] ].each do |width, height|
    test "a card opens on the start of its latest message at #{width} pixels wide" do
      original_size = page.current_window.size
      page.current_window.resize_to(width, height)

      visit card_url(@card)
      assert_message_below_title_bar @latest
    ensure
      page.current_window.resize_to(*original_size)
    end
  end

  test "a card opened from its board shows the latest message" do
    # Maybe? is the board's open column; the others start collapsed.
    @card.send_back_to_triage(skip_event: true)

    visit board_url(@card.board)
    find("a.card__link[href='#{card_path(@card)}']").click

    assert_current_path card_path(@card)
    assert_message_below_title_bar @latest
  end

  test "a link to an older message still opens on that message" do
    visit card_url(@card, anchor: dom_id(@older))

    assert_selector "##{dom_id(@latest)}"
    assert_message_at_top @older, margin: 0
  end

  test "going back to a card keeps where the reader left it" do
    visit card_url(@card)
    assert_message_below_title_bar @latest

    # Turbo saves the position from scroll events: wait for the page to react first.
    page.execute_script("window.scrollTo(0, 0)")
    assert_no_selector ".card-title-bar", wait: 5
    page.execute_script("Turbo.visit('#{board_path(@card.board)}')")
    assert_current_path board_path(@card.board)

    # Turbo restores what it saved, which can be a few pixels off when the board
    # scrolls late; the card's header must still be on screen, not the latest message.
    page.go_back
    assert_current_path card_path(@card)
    assert_selector "##{dom_id(@latest)}"
    sleep 0.5
    assert page.evaluate_script(%(document.querySelector(".card__header").getBoundingClientRect().bottom > 0)),
      "going back should keep the top of the card, not jump to the latest message"
  end

  test "a card without messages opens at the top" do
    @card.comments.destroy_all

    visit card_url(@card)
    assert_selector ".card__header"
    assert_stays_at_top
  end

  private
    def dom_id(record)
      ActionView::RecordIdentifier.dom_id(record)
    end

    # The message starts 16 pixels below the title bar, which shows once the card
    # scrolls away and would otherwise cover the message's author line.
    def assert_message_below_title_bar(comment)
      assert_selector ".card-title-bar", wait: 5
      assert_message_at_top comment, margin: %(document.querySelector(".card-title-bar").getBoundingClientRect().bottom + 16)
    end

    # An anchor puts the message flush with the top.
    def assert_message_at_top(comment, margin:)
      script = %(Math.abs(document.getElementById("#{dom_id(comment)}").getBoundingClientRect().top - (#{margin})) <= 1)
      Timeout.timeout(5) { sleep 0.1 until page.evaluate_script(script) }
    rescue Timeout::Error
      flunk "#{dom_id(comment)} should start at #{page.evaluate_script(margin.to_s)} pixels from the top, " \
        "but starts at #{page.evaluate_script(%(document.getElementById("#{dom_id(comment)}").getBoundingClientRect().top))}"
    end

    # Give a late scroll the time to happen before deciding it did not.
    def assert_stays_at_top
      sleep 0.5
      assert_equal 0, page.evaluate_script("window.scrollY")
    end
end
