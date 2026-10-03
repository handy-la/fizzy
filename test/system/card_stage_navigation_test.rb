require "application_system_test_case"

class CardStageNavigationTest < ApplicationSystemTestCase
  setup do
    sign_in_as(users(:kevin))
  end

  test "Done from the mobile header offers Continue to another source card" do
    original_size = page.current_window.size
    page.current_window.resize_to(390, 844)
    visit card_url(cards(:logo))

    find(".card__quick-done").click

    assert_selector ".approval-toast"

    # A real card refresh must not discard the next-card action.
    Current.user = users(:kevin)
    cards(:logo).reload.update!(title: "Done card refreshed")
    perform_enqueued_jobs only: Turbo::Streams::BroadcastStreamJob
    assert_selector "h1", text: "Done card refreshed"
    assert_selector ".approval-toast", count: 1

    click_on "Undo"
    assert_no_selector ".approval-toast"
    find(".card__quick-done").click
    assert_selector ".approval-toast", count: 1

    within ".approval-toast" do
      assert_text cards(:layout).title
      click_on "Continue"
    end

    assert_current_path card_path(cards(:layout))
    assert_selector "h1", text: cards(:layout).title
    assert_no_selector ".approval-toast"
  ensure
    page.current_window.resize_to(*original_size)
  end

  test "the stage selector and the dock offer one dismissible source notice" do
    visit card_url(cards(:logo))
    within ".card__stages" do
      click_on "In progress"
    end

    assert_selector ".approval-toast", count: 1
    within ".approval-toast" do
      assert_text cards(:layout).title
    end

    # Moving again must replace the notice even if it was not dismissed.
    page.execute_script("window.scrollTo(0, document.body.scrollHeight)")
    find('.card-dock button[title="Move to Triage"]').click

    assert_selector ".approval-toast", count: 1
    within ".approval-toast" do
      assert_text cards(:text).title
      click_on "Dismiss"
    end
    assert_no_selector ".approval-toast"

    within ".card__stages" do
      click_on "Maybe?"
    end
    assert_selector ".approval-toast", count: 1
    within ".approval-toast" do
      assert_text cards(:layout).title
    end
  end
end
