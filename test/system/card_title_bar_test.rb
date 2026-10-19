require "application_system_test_case"

class CardTitleBarTest < ApplicationSystemTestCase
  setup do
    sign_in_as(users(:david))
    @card = cards(:layout)
    @card.update!(description: Array.new(15) { |line| "<p>Paragraph #{line} of the card description.</p>" }.join)
    @card.comments.create!(creator: users(:david), body: "<p>A long comment for scrolling.</p>" * 50)
  end

  [ [ 1280, 800 ], [ 390, 844 ] ].each do |width, height|
    test "the title follows the card at #{width} pixels wide" do
      original_size = page.current_window.size
      page.current_window.resize_to(width, height)
      visit card_url(@card)
      assert_selector ".card-perma__bg"
      # A card opens on its latest message (Handy #1265); this case scrolls from the top.
      page.execute_script("window.scrollTo(0, 0)")
      assert_no_selector ".card-title-bar"

      page.execute_script('window.scrollBy(0, document.querySelector(".card__header").getBoundingClientRect().bottom + 20)')
      assert_selector ".card-dock--visible", wait: 5
      assert_no_selector ".card-title-bar"

      scroll_past_card
      assert_title_bar(@card.title)
      assert_bar_matches_card_colors
      assert_bar_fills_top_edge

      page.execute_script("window.scrollBy(0, 200)")
      assert_title_bar(@card.title)
      assert_bar_fills_top_edge

      page.execute_script("window.scrollTo(0, 0)")
      assert_no_selector ".card-title-bar", wait: 5
      assert page.evaluate_script('document.querySelector(".card-perma__bg").getBoundingClientRect().top >= 0')
    ensure
      page.current_window.resize_to(*original_size)
    end
  end

  test "a broadcast refresh keeps the bar visible and updates its title" do
    visit card_url(@card)
    scroll_past_card
    assert_title_bar(@card.title)
    assert_selector "turbo-cable-stream-source[connected]", visible: :all
    assert_no_selector "turbo-cable-stream-source:not([connected])", visible: :all

    Current.user = users(:kevin)
    @card.update!(title: "A new title from another session")
    @card.triage_into(columns(:writebook_review))
    perform_enqueued_jobs only: Turbo::Streams::BroadcastStreamJob

    assert_title_bar("A new title from another session")
    assert_bar_matches_card_colors
    assert_bar_fills_top_edge

    within(".card-dock") { click_on "Mark as Done" }
    assert_selector ".card-dock__button--closed"
    assert_bar_matches_card_colors

    page.execute_script("window.scrollTo(0, 0)")
    assert_no_selector ".card-title-bar", wait: 5
  end

  test "saving a title in the current session updates the bar" do
    visit card_url(@card)
    click_on @card.title
    fill_in "card_title", with: "A title saved in this session"
    click_on "Save changes"
    assert_selector ".card__title-link", text: "A title saved in this session"

    scroll_past_card
    assert_title_bar("A title saved in this session")
  end

  private
    def scroll_past_card
      page.execute_script('window.scrollBy(0, document.querySelector(".card-perma__bg").getBoundingClientRect().bottom + 20)')
    end

    def assert_title_bar(title)
      assert_selector ".card-title-bar", text: title, wait: 5
    end

    def assert_bar_matches_card_colors
      colors = page.evaluate_script(<<~JS)
        (() => {
          // Compare the settled state, after the header's color transition.
          document.querySelector(".card__board").getAnimations().forEach(animation => animation.finish())
          const bar = getComputedStyle(document.querySelector(".card-title-bar"))
          const board = getComputedStyle(document.querySelector(".card__board"))
          return { barBackground: bar.backgroundColor, boardBackground: board.backgroundColor,
            barText: bar.color, boardText: board.color }
        })()
      JS
      assert_equal colors["boardBackground"], colors["barBackground"], "the bar should keep the current state's background"
      assert_equal colors["boardText"], colors["barText"], "the bar should keep the card header's text contrast"
    end

    def assert_bar_fills_top_edge
      geometry = page.evaluate_script(<<~JS)
        (() => {
          const bar = document.querySelector(".card-title-bar")
          const rect = bar.getBoundingClientRect()
          return { top: rect.top, left: rect.left, right: rect.right,
            width: document.documentElement.clientWidth, position: getComputedStyle(bar).position }
        })()
      JS
      assert_equal "fixed", geometry["position"]
      assert_in_delta 0, geometry["top"], 1
      assert_in_delta 0, geometry["left"], 1
      assert_in_delta geometry["width"], geometry["right"], 1
    end
end
