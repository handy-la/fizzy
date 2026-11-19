require "application_system_test_case"
require "tempfile"

# Authoring and RED: docs/test-audits/handy-2575.md.
class TickHealthsTest < ApplicationSystemTestCase
  setup do
    Current.session = sessions(:david)
    @board = boards(:writebook)
    @column = columns(:writebook_review)
    @registry = Tempfile.new([ "tick-registry", ".json" ])
    @registry.write({ schema: 1, products: [ {
      id: "example", account_id: @board.account.external_account_id.to_s, board_id: @board.id,
      producer_user_id: users(:david).id,
      stages: [
        { id: "deploying", column_id: @column.id, description: "Comprobar despliegues" },
        { id: "publishing", column_id: columns(:writebook_on_hold).id, description: "Comprobar publicación" }
      ]
    } ] }.to_json)
    @mike_settings = users(:mike).create_settings! unless users(:mike).settings
    @other_column = boards(:miltons_wish_list).columns.create!(name: "Publicación", color: "var(--color-card-default)")
    @registry.flush
    document = JSON.parse(File.read(@registry.path))
    document["products"] << {
      "id" => "other-product", "account_id" => accounts(:initech).external_account_id.to_s,
      "board_id" => @other_column.board_id, "producer_user_id" => users(:mike).id,
      "stages" => [ { "id" => "publishing", "column_id" => @other_column.id, "description" => "Publicar otro producto" } ]
    }
    File.write(@registry.path, document.to_json)
    @previous_registry = ENV["TICK_HEALTH_REGISTRY_FILE"]
    ENV["TICK_HEALTH_REGISTRY_FILE"] = @registry.path
    # No fixture table: system tests commit rows for Cable and must clean them.
    TickHealth.delete_all
    @column.cards.update_all(column_id: nil)
    sign_in_as users(:david)
  end

  teardown do
    TickHealth.delete_all
    ENV["TICK_HEALTH_REGISTRY_FILE"] = @previous_registry
    @registry.close!
    @other_column.destroy!
    @mike_settings&.destroy!
  end

  test "empty configured columns show health while human columns have no indicator" do
    visit board_url(@board)
    expand @column
    within("##{dom_id(@column)}") do
      assert_selector ".tick-health__button", text: "Sin señal"
      find(".tick-health__button").hover
    end
    within ".tick-health__detail:popover-open" do
      assert_text "Sin señal recibida"
      assert_text "Sin estimación"
    end
    within("##{dom_id(columns(:writebook_triage))}") { assert_no_selector ".tick-health", visible: :all }
    assert_selector ".tick-health", count: 2, visible: :all
  end

  test "a committed phase arrives through Cable in two sessions without reloading or crossing boards" do
    visit board_url(@board)
    expand @column
    wait_for_tick
    page.execute_script("window.tickMarker = true")

    using_session(:tick_second) do
      sign_in_as users(:david)
      visit board_url(@board)
      expand @column
      wait_for_tick
      page.execute_script("window.tickMarker = true")
    end
    using_session(:tick_private) do
      sign_in_as users(:kevin)
      visit board_url(boards(:private))
      assert_no_selector ".tick-health", visible: :all
    end

    using_session(:tick_other_account) do
      previous_options = default_url_options
      self.default_url_options = default_url_options.merge(script_name: "/#{accounts(:initech).external_account_id}")
      sign_in_as users(:mike)
      visit board_url(@other_column.board, script_name: "/#{accounts(:initech).external_account_id}")
      expand @other_column
      assert_selector ".tick-health__button", text: "Sin señal"
    ensure
      self.default_url_options = previous_options
    end

    write state: "running"
    assert_selector "##{dom_id(@column)} .tick-health__button", text: "En curso", wait: 10
    assert page.evaluate_script("window.tickMarker")
    using_session(:tick_second) do
      assert_selector "##{dom_id(@column)} .tick-health__button", text: "En curso", wait: 10
      assert page.evaluate_script("window.tickMarker")
    end
    using_session(:tick_other_account) do
      assert_selector ".tick-health__button", text: "Sin señal"
      assert_no_text "Comprobando despliegue"
    end
    using_session(:tick_private) do
      assert_no_selector ".tick-health", visible: :all
      assert_no_text "Comprobando despliegue"
    end
  end

  test "reconnect recovers the persisted phase and duplicate or old snapshots cannot revert it" do
    write state: "running"
    visit board_url(@board)
    expand @column
    wait_for_tick
    run_controller "controller.disconnect()"
    write state: "waiting_ci", expected_event: "Resultado de CI"
    run_controller "controller.connect()"
    assert_selector "##{dom_id(@column)} .tick-health__button", text: "Esperando CI", wait: 10
    snapshot = TickHealth.snapshot(@board).deep_stringify_keys
    run_controller "controller.receive(arguments[0])", snapshot
    snapshot["stages"].find { it["stage_id"] == "deploying" }.merge!("revision" => 1, "state" => "failed")
    run_controller "controller.receive(arguments[0])", snapshot
    assert_selector "##{dom_id(@column)} .tick-health__button", text: "Esperando CI"
    page.execute_script("window.tickMarker = true")
    run_controller "controller.buttonTarget.focus()"
    find("##{dom_id(@column)} .tick-health__button").send_keys(:enter)
    assert_selector ".tick-health__detail:popover-open", text: "Resultado de CI"
    assert page.evaluate_script("window.tickMarker")
    find("##{dom_id(@column)} .tick-health__button").send_keys(:escape)
    assert_no_selector ".tick-health__detail:popover-open"
  end

  test "keyboard touch and expiry show details without turning a previous failure into current failure" do
    write state: "running"
    visit board_url(@board)
    expand @column
    button = find("##{dom_id(@column)} .tick-health__button")
    page.execute_script("arguments[0].focus()", button)
    assert_selector ".tick-health__detail:popover-open", text: "Último resultado"
    assert_selector ".tick-health__detail:popover-open", text: "Fallido"
    button.send_keys(:enter)
    page.execute_script("arguments[0].blur()", button)
    assert_selector ".tick-health__detail:popover-open", text: "En curso"
    button.send_keys(:escape)

    window = Capybara.current_session.current_window
    original_size = window.size
    window.resize_to(390, 844)
    visit board_column_url(@board, @column)
    button = find(".tick-health__button")
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true, maxTouchPoints: 1)
    rect = page.evaluate_script("(r => ({ x: r.x+r.width/2, y: r.y+r.height/2 }))(arguments[0].getBoundingClientRect())", button)
    page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: "touchStart", touchPoints: [ rect ])
    page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: "touchEnd", touchPoints: [])
    assert_selector ".tick-health__detail:popover-open", text: "La próxima corrida no es una estimación de entrega"
    page.execute_script("const realNow = Date.now; Date.now = () => realNow() + 3600000")
    element = find("[data-controller~=tick-health]")
    page.execute_script("window.Stimulus.getControllerForElementAndIdentifier(arguments[0], 'tick-health').refresh()", element)
    assert_selector ".tick-health__button", text: "Desactualizado"
    assert_selector ".tick-health__detail:popover-open", text: "Fuente desactualizada"
  ensure
    window&.resize_to(*original_size) if original_size
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
  end

  test "expanded health stays at the base without moving the header when evidence changes" do
    visit board_url(@board)
    expand @column
    settle_columns
    wait_for_tick
    title = find("##{dom_id(@column)} .cards__expander-title")
    button = find("##{dom_id(@column)} .tick-health__button")
    assert_operator rect(button)["top"], :>, rect(title)["bottom"]
    column_rect = rect(find("##{dom_id(@column)}"))
    assert_in_delta column_rect["bottom"], rect(button)["bottom"], 1
    baseline = header_geometry

    [ [ "running", "En curso" ], [ "failed", "Último intento fallido" ], [ "waiting_resource", "Esperando recurso" ] ].each do |state, label|
      write state: state, expected_event: "Disponibilidad del recurso"
      assert_selector "##{dom_id(@column)} .tick-health__button", text: label, wait: 10
      header_geometry.each_with_index do |value, index|
        assert_in_delta baseline[index], value, 0.5, "the label must not move the title, header or cards"
      end
    end
  end

  test "folded health is a visible vertical control that keeps the stage closed on keyboard use" do
    write state: "running"
    visit board_url(@board)
    expander = find("##{dom_id(@column)} .cards__expander")
    expander.find(".cards__expander-title").click if expander["aria-expanded"] == "true"
    settle_columns
    assert_selector "##{dom_id(@column)}.is-collapsed"
    assert_selector "##{dom_id(@column)} .tick-health__button", text: "En curso"
    button = find("##{dom_id(@column)} .tick-health__button", text: "En curso")
    assert_selector "##{dom_id(@column)} .tick-health__state"
    assert_equal "vertical-rl", page.evaluate_script("getComputedStyle(arguments[0]).writingMode", button.find(".tick-health__state"))
    column_rect = rect(find("##{dom_id(@column)}"))
    assert_operator rect(button)["width"], :>=, 24
    assert page.evaluate_script("arguments[0].scrollHeight <= arguments[0].clientHeight + 1", button.find("[data-tick-health-target=label]")), "the vertical state must remain readable"
    assert page.evaluate_script("arguments[0].scrollHeight <= arguments[0].clientHeight + 1", button.find(".tick-health__next")), "the vertical countdown must remain readable"
    assert_operator rect(button)["left"], :>=, column_rect["left"]
    assert_operator rect(button)["right"], :<=, column_rect["right"] + 0.5
    state_rect = rect(button.find(".tick-health__state"))
    schedule_rect = rect(button.find(".tick-health__schedule"))
    assert_operator state_rect["left"], :>=, schedule_rect["right"] - 0.5
    [ state_rect, schedule_rect ].each do |lane|
      assert_operator lane["top"], :>=, rect(button)["top"]
      assert_operator lane["bottom"], :<=, rect(button)["bottom"]
    end
    assert_in_delta column_rect["bottom"], rect(button)["bottom"], 1
    assert_selector "##{dom_id(@column)} .tick-health__next", text: /\d{2}:\d{2}:\d{2}/
    page.execute_script("arguments[0].focus()", button)
    button.send_keys(:enter)
    assert_selector ".tick-health__detail:popover-open", text: "Fase actual"
    assert_selector "##{dom_id(@column)}.is-collapsed"
    button.send_keys(:escape)
    assert_no_selector ".tick-health__detail:popover-open"

    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true, maxTouchPoints: 1)
    area = rect(button)
    point = { x: area["x"] + area["width"] / 2, y: area["y"] + area["height"] / 2 }
    page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: "touchStart", touchPoints: [ point ])
    page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: "touchEnd", touchPoints: [])
    assert_selector ".tick-health__detail:popover-open", text: "Fase actual"
    assert_selector "##{dom_id(@column)}.is-collapsed"
  ensure
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
  end

  test "status icons differ and the next tick clock advances without inventing a run after expiry" do
    write state: "scheduled"
    visit board_url(@board)
    expand @column
    wait_for_tick
    selector = "##{dom_id(@column)}"
    assert_selector "#{selector} .tick-health__next", text: /00:0[45]:[0-5]\d/
    initial = find("#{selector} .tick-health__next").text
    page.execute_script("window.tickClockOriginal = Date.now; Date.now = () => window.tickClockOriginal() + 2000")
    assert_no_selector "#{selector} .tick-health__next", exact_text: initial, wait: 3
    icons = []
    %w[scheduled running waiting_ci waiting_resource deferred lock_busy noop failed no_signal scheduler_missing disabled].each do |state|
      write state: state, expected_event: "Resultado esperado"
      assert_selector "#{selector} .tick-health__icon[data-state='#{state}']", wait: 10
      icons << find("#{selector} .tick-health__icon path", visible: :all)["d"]
    end
    assert_equal icons.length, icons.uniq.length
    write state: "scheduled"
    assert_selector "#{selector} .tick-health__button", text: "Programado", wait: 10
    page.execute_script("Date.now = () => window.tickClockOriginal() + 301000")
    assert_selector "#{selector} .tick-health__next", text: "Pendiente", wait: 3
    assert_selector "#{selector} .tick-health__button", text: "Programado"
    page.execute_script("Date.now = () => window.tickClockOriginal() + 601000")
    assert_selector "#{selector} .tick-health__button", text: "Desactualizado", wait: 3
    assert_selector "#{selector} .tick-health__next", text: "No disponible"
    assert_selector "#{selector} .tick-health__icon[data-state='stale']"
    assert_equal icons.length + 1, (icons + [ find("#{selector} .tick-health__icon path", visible: :all)["d"] ]).uniq.length
  end

  private
    def settle_columns
      page.evaluate_async_script(<<~JS)
        const done = arguments[0]
        Promise.all(document.getAnimations().map(animation => animation.finished.catch(() => {}))).then(() => done())
      JS
    end

    def rect(element)
      page.evaluate_script("arguments[0].getBoundingClientRect().toJSON()", element)
    end

    def header_geometry
      column = find("##{dom_id(@column)}")
      title = rect(column.find(".cards__expander-title"))
      header = rect(column.find(".cards__header"))
      frame = rect(column.find("turbo-frame", visible: :all))
      [ title["x"], title["y"], title["height"], header["height"], frame["y"] ]
    end

    def expand(column)
      button = find("##{dom_id(column)} .cards__expander")
      button.find(".cards__expander-title").click unless button["aria-expanded"] == "true"
    end

    def wait_for_tick
      assert_selector "##{dom_id(@column)} .tick-health__button"
      assert_selector "##{dom_id(@column)} .tick-health__detail", text: "Conectada", visible: :all, wait: 10
    end

    def run_controller(script, *args)
      element = find("##{dom_id(@column)} [data-controller~=tick-health]", visible: :all)
      page.execute_script("const controller = window.Stimulus.getControllerForElementAndIdentifier(arguments[arguments.length-1], 'tick-health'); #{script}", *args, element)
    end

    def write(state:, expected_event: nil)
      row = TickHealth.find_by(board: @board, stage_id: "deploying")
      body = JSON.parse(file_fixture("tick_health/v1.json").read).merge(
        "expected_revision" => row&.revision || 0, "state" => state, "expected_event" => expected_event,
        "reported_at" => Time.current.utc.iso8601, "phase_started_at" => 2.minutes.ago.utc.iso8601,
        "valid_until" => 10.minutes.from_now.utc.iso8601, "next_run_at" => (state.in?(%w[disabled scheduler_missing]) ? nil : 5.minutes.from_now.utc.iso8601),
        "last_finished_at" => 5.minutes.ago.utc.iso8601)
      result = TickHealth::Declaration.write(board: @board, stage_id: "deploying", body: body, user: users(:david))
      assert_includes [ :created, :updated ], result.code
    end
end
