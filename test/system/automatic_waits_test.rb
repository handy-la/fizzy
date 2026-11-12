require "application_system_test_case"

# Authoring answers: docs/test-audits/handy-2306.md.
class AutomaticWaitsTest < ApplicationSystemTestCase
  include ActionView::RecordIdentifier
  # The suite's own browser: nothing here depends on pointer media queries, and
  # the touch case turns CDP touch emulation off again in `ensure`.
  BUTTON = ".card__automatic-waits-button"
  POPOVER = ".card__automatic-waits-popover"

  setup do
    Current.session = sessions(:david)
    # In "Maybe?", the column a board shows expanded.
    @card = cards(:buy_domain)
    @card.comments.destroy_all
    Capybara.using_wait_time(10) { sign_in_as(users(:david)) }
  end

  test "the clock sits above the comment count, also with zero comments" do
    declare "ci:rails-test", reason: "CI de rails en ejecución"
    visit board_url(@card.board)

    within card_preview do
      assert_selector BUTTON, count: 1
      assert_no_selector ".card__comments"
    end

    @card.comments.create!(body: "Un comentario", creator: users(:david))
    visit board_url(@card.board)

    within card_preview do
      assert_selector ".card__comments", text: "1"
      clock = find("#{BUTTON} .icon").native.rect
      comments = find(".card__comments").native.rect
      assert_operator clock.y + clock.height, :<=, comments.y, "the clock is above the comment count"
    end
  end

  test "hover shows every reason and keeps the card where it is" do
    declare "ci:rails-test", reason: "CI de rails en ejecución", next_check_at: 3.minutes.from_now + 20.seconds
    declare "monitor:fleet", reason: "Monitor de flota", producer: "monitor", state: "monitoring", next_check_at: nil,
      expected_event: "Reporte del monitor de flota"
    visit board_url(@card.board)

    assert_no_selector POPOVER, visible: true
    within(card_preview) { find(BUTTON).hover }

    within POPOVER, visible: true do
      assert_text "Esperando al sistema"
      assert_text "No requiere intervención humana"
      assert_text "CI de rails en ejecución"
      assert_text "Próxima revisión en aproximadamente 4 min"
      assert_text "Monitor de flota"
      assert_text "Espera: Reporte del monitor de flota"
    end
    assert_current_path board_path(@card.board)
  end

  test "keyboard focus shows the reasons, Enter pins them and Escape closes them" do
    declare "ci:rails-test", reason: "CI de rails en ejecución"
    visit board_url(@card.board)

    button = within(card_preview) { find(BUTTON) }
    page.execute_script("arguments[0].focus()", button)
    assert_selector POPOVER, visible: true, text: "Esperando al sistema"

    button.send_keys(:enter)
    page.execute_script("arguments[0].blur()", button)
    assert_selector POPOVER, visible: true, text: "CI de rails en ejecución"
    assert_current_path board_path(@card.board)

    page.execute_script("arguments[0].focus()", button)
    button.send_keys(:space)
    assert_no_selector POPOVER, visible: true
    button.send_keys(:space)
    assert_selector POPOVER, visible: true

    page.execute_script("arguments[0].focus()", button)
    button.send_keys(:escape)
    assert_no_selector POPOVER, visible: true
    assert_current_path board_path(@card.board)
  end

  test "a tap shows the reasons instead of opening the card" do
    declare "ci:rails-test", reason: "CI de rails en ejecución", human_condition: "pending"
    window = Capybara.current_session.current_window
    original_size = window.size
    window.resize_to(390, 844)
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true, maxTouchPoints: 1)
    visit board_url(@card.board)

    button = within(card_preview) { find(BUTTON) }
    scroll_to button, align: :center
    rect = page.evaluate_script("(b => ({ x: b.x + b.width / 2, y: b.y + b.height / 2 }))(arguments[0].getBoundingClientRect())", button)
    page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: "touchStart", touchPoints: [ { x: rect["x"], y: rect["y"] } ])
    page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: "touchEnd", touchPoints: [])

    within POPOVER, visible: true do
      assert_text "Esperando al sistema"
      assert_text "Hay una decisión humana pendiente"
      assert_text "Decisión humana pendiente"
      assert_no_text "No requiere intervención humana"
    end
    assert_current_path board_path(@card.board)
  ensure
    window.resize_to(*original_size)
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
  end

  test "a declaration arrives live, without a reload and without a second control" do
    visit board_url(@card.board)
    wait_for_cable_subscriptions
    page.execute_script("window.automaticWaitMarker = true")
    within(card_preview) { assert_no_selector BUTTON }

    declare "ci:rails-test", reason: "CI de rails en cola", state: "queued"
    perform_enqueued_jobs only: Turbo::Streams::BroadcastStreamJob
    within(card_preview) { assert_selector BUTTON, count: 1, wait: 10 }

    declare "monitor:fleet", reason: "Monitor de flota", producer: "monitor", state: "monitoring"
    perform_enqueued_jobs only: Turbo::Streams::BroadcastStreamJob
    within(card_preview) { find(BUTTON).hover }
    assert_selector "#{POPOVER} li", count: 2, visible: true, wait: 10
    within(card_preview) { assert_selector BUTTON, count: 1 }

    assert page.evaluate_script("window.automaticWaitMarker === true"), "the page was not reloaded"
  end

  test "at zero the review reads pending, then overdue, and past validity out of date" do
    declare "ci:rails-test", reason: "CI de rails en ejecución", next_check_at: 1.minute.from_now, valid_until: 20.minutes.from_now
    visit board_url(@card.board)

    clock_at(2.minutes.from_now)
    within(card_preview) { find(BUTTON).hover }
    assert_selector POPOVER, visible: true, text: "Revisión pendiente"

    clock_at(10.minutes.from_now)
    assert_selector POPOVER, visible: true, text: "Revisión vencida"
    assert_selector POPOVER, visible: true, text: "No requiere intervención humana"

    clock_at(25.minutes.from_now)
    assert_selector POPOVER, visible: true, text: "Seguimiento desactualizado"
    assert_no_selector POPOVER, visible: true, text: "No requiere intervención humana"
    within(card_preview) { assert_selector BUTTON, count: 1 }
  end

  private
    # A broadcast sent before the page's subscriptions are confirmed is lost.
    def wait_for_cable_subscriptions
      assert_selector "turbo-cable-stream-source[connected]", visible: :all
      assert_no_selector "turbo-cable-stream-source:not([connected])", visible: :all
    end

    def card_preview
      find("##{dom_id(@card, :article)}")
    end

    # Moves the browser's clock and asks the controller to recompute, as its
    # timer does every 15 seconds.
    def clock_at(time)
      page.execute_script(<<~JS, (time.to_f * 1000).to_i)
        const offset = arguments[0] - Date.now()
        const realNow = Date.now.bind(Date)
        Date.now = () => realNow() + offset
        const element = document.querySelector("[data-controller~=automatic-wait]")
        window.Stimulus.getControllerForElementAndIdentifier(element, "automatic-wait").refresh()
      JS
    end

    def declare(key, reason:, producer: "ci", state: "running", next_check_at: 3.minutes.from_now,
                valid_until: 1.hour.from_now, human_condition: "not_required", expected_event: "Resultado de #{key}")
      existing = @card.automatic_waits.find_by(key: key)
      body = {
        "epoch" => @card.reload.automatic_wait_epoch, "expected_revision" => existing&.revision || 0,
        "owner" => "dedalo:handy", "run_id" => "run-1", "run_sequence" => 1,
        "producer" => producer, "state" => state, "reason" => reason, "expected_event" => expected_event,
        "valid_until" => valid_until.utc.iso8601, "human_condition" => human_condition
      }
      body["next_check_at"] = next_check_at.utc.iso8601 if next_check_at

      result = Card::AutomaticWait::Declaration.declare(card: @card, key: key, body: body, user: users(:david))
      raise "#{key}: #{result.code} #{result.details}" unless result.success?
    end
end
