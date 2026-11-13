require "application_system_test_case"

# Authoring answers: docs/test-audits/handy-2348.md.
class WorkMapSystemTest < ApplicationSystemTestCase
  include WorkMapTestHelper

  setup do
    Current.session = sessions(:kevin)
    @a = boards(:private).cards.create!(title: "Prerrequisito en Beta", creator: users(:kevin), status: "published")
    @b = cards(:text)
    @c = cards(:logo)
    ENV["WORK_MAP_SOURCE_FILE"] = work_map_file(work_map_answer(
      products: [ work_map_product("alpha", boards(:writebook), name: "Alpha"), work_map_product("beta", boards(:private), name: "Beta") ],
      items: [ work_map_item("alpha", @b, state: "held", wait: work_map_wait(kind: "card", reason: "Espera la publicación de Beta")),
        work_map_item("beta", @a, state: "working") ],
      relations: [ work_map_relation([ "beta", @a ], [ "alpha", @b ], condition: "publication"),
        work_map_relation([ "alpha", @b ], [ "alpha", @c ], condition: "integration") ]))
    Capybara.using_wait_time(10) { sign_in_as(users(:kevin)) }
  end

  teardown do
    ENV.delete("WORK_MAP_SOURCE_FILE")
  end

  test "every product shows at once, and choosing a card lights up its chain and opens its detail" do
    visit work_map_url

    within ".work-map__coverage" do
      assert_text "Alpha: al día"
      assert_text "Beta: al día"
    end
    assert_selector node(@a)
    assert_selector node(@b)
    assert_selector ".work-map__edge--pending", count: 2

    find(node(@b)).click

    within ".work-map__panel" do
      assert_text "Alpha ##{@b.number}"
      assert_text "otra tarjeta"
      assert_text "Espera la publicación de Beta"
      assert_text "Beta ##{@a.number}: publicación, vigente"
      assert_text "Alpha ##{@c.number}: integración a main, vigente"
      assert_selector "a[href='#{card_path(@b)}']", text: "Abrir tarjeta"
    end
    # A related card may sit outside the visible part of the canvas.
    assert_selector "#{node(@a)}.is-upstream", visible: :all
    assert_selector "#{node(@c)}.is-downstream", visible: :all

    find(node(@a)).click
    within(".work-map__panel") { assert_text "Resolverla destrabaría 2 tarjetas" }
  end

  test "the keyboard moves between cards, opens one, and controls the view" do
    visit work_map_url
    canvas = find(".work-map__canvas")
    canvas.click
    canvas.send_keys("0")
    scale = canvas["data-scale"]

    canvas.send_keys(:add)
    assert_no_selector ".work-map__canvas[data-scale='#{scale}']"
    canvas.send_keys("0")
    assert_selector ".work-map__canvas[data-scale='#{scale}']"

    canvas.send_keys(:arrow_down)
    assert_selector ".work-map__node.is-selected", count: 1
    canvas.send_keys(:arrow_left)
    assert_current_path work_map_path, ignore_query: true
    assert_selector ".work-map__panel", visible: true
    assert_no_selector "button[data-work-map-target=chainButton][disabled]"

    canvas.send_keys(:escape)
    assert_no_selector ".work-map__node.is-selected"

    find(node(@b)).click
    canvas.send_keys(:enter)
    assert_current_path card_path(@b)
  end

  test "search by product and number, filters, and reset bring every product back" do
    visit work_map_url

    fill_in "Buscar tarjeta", with: "beta #{@a.number}\n"
    assert_selector "#{node(@a)}.is-selected"

    find(".work-map__filters summary").click
    within(".work-map__filters-body") { check "Alpha" }
    assert_no_selector node(@a)
    assert_selector node(@b)
    assert_text "1 relaciones tienen un extremo oculto por los filtros"

    fill_in "Buscar tarjeta", with: "beta #{@a.number}\n"
    assert_text "los filtros la ocultan"

    within(".work-map__filters-body") { click_on "Restablecer filtros" }
    assert_selector node(@a)
    assert_no_text "oculto por los filtros"
  end

  # Handy #2412: a postponed card is never a card of the map, with or without
  # filters; its relation shows a postponed reference beside the related card.
  test "a postponed card stays off the map in the joint view, under a product filter and after a reset" do
    @c.postpone(user: users(:kevin))
    visit work_map_url

    assert_selector node(@b)
    assert_no_selector node(@c)
    assert_selector ".work-map__node--postponed", text: "Pospuesta (Not Now)"
    assert_text "#{all(".work-map__node--card").size} tarjetas en el mapa"

    find(".work-map__filters summary").click
    within(".work-map__filters-body") { check "Alpha" }
    assert_no_selector node(@c)
    assert_selector ".work-map__node--postponed"
    assert_text "#{all(".work-map__node--card").size} tarjetas en el mapa"

    within(".work-map__filters-body") { uncheck "Alpha"; check "Beta" }
    assert_no_selector node(@b)
    assert_no_selector ".work-map__node--postponed"
    assert_text "1 tarjetas en el mapa"

    within(".work-map__filters-body") { click_on "Restablecer filtros" }
    assert_selector node(@b)
    assert_no_selector node(@c)
    assert_text "#{all(".work-map__node--card").size} tarjetas en el mapa"
  end

  # Handy #2372: a filter that hides the chosen card clears the selection, and
  # the panel and «Enfocar cadena» follow it.
  test "a filter that hides the chosen card empties the panel and disables the chain button" do
    visit work_map_url
    find(node(@a)).click
    within(".work-map__panel") { assert_text "Beta ##{@a.number}" }
    assert_no_selector "button[data-work-map-target=chainButton][disabled]"

    find(".work-map__filters summary").click
    within(".work-map__filters-body") { check "Alpha" }

    assert_no_selector node(@a)
    assert_no_selector ".work-map__panel", visible: true
    assert_no_text "Beta ##{@a.number}"
    assert_selector "button[data-work-map-target=chainButton][disabled]"
  end

  # Handy #2372: a dependent that still waits on another pending prerequisite
  # is not released by resolving this card.
  test "the release count leaves out a dependent that still has another pending prerequisite" do
    other = cards(:shipping)
    ENV["WORK_MAP_SOURCE_FILE"] = work_map_file(work_map_answer(
      products: [ work_map_product("alpha", boards(:writebook), name: "Alpha"), work_map_product("beta", boards(:private), name: "Beta") ],
      relations: [ work_map_relation([ "beta", @a ], [ "alpha", @b ]), work_map_relation([ "alpha", other ], [ "alpha", @b ]),
        work_map_relation([ "beta", @a ], [ "alpha", @c ]) ]))
    visit work_map_url

    find(node(@a)).click

    within(".work-map__panel") do
      assert_text "Resolverla destrabaría 1 tarjeta, directas y transitivas: Alpha ##{@c.number}."
      assert_no_text "destrabaría 2"
    end
  end

  test "a tap on a phone chooses the card" do
    window = Capybara.current_session.current_window
    original_size = window.size
    window.resize_to(390, 844)
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true, maxTouchPoints: 2)
    visit work_map_url

    target = find(node(@b))
    rect = page.evaluate_script("(n => ({ x: n.x + n.width / 2, y: n.y + n.height / 2 }))(arguments[0].getBoundingClientRect())", target)
    page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: "touchStart", touchPoints: [ { x: rect["x"], y: rect["y"] } ])
    page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: "touchEnd", touchPoints: [])

    within(".work-map__panel") { assert_text "Alpha ##{@b.number}" }
  ensure
    window.resize_to(*original_size)
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
  end

  test "a failed source is said per product, never shown as an empty map" do
    ENV["WORK_MAP_SOURCE_FILE"] = work_map_file("{ roto")
    visit work_map_url

    assert_text "La fuente de ejecución de Dédalo falló (invalid_json)"
    within(".work-map__coverage") { assert_text "Writebook: fuente de ejecución fallida" }
    assert_selector node(@b)
  end

  private
    def node(card)
      ".work-map__node[data-node-id='card-#{card.number}']"
    end
end
