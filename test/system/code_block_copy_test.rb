require "application_system_test_case"

class CodeBlockCopyTest < ApplicationSystemTestCase
  # Linux headless has no physical pointer. Give this browser a desktop pointer;
  # the touch case changes it through CDP, as Chrome's device emulator does.
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1200, 1000 ] do |options|
    options.add_argument("--blink-settings=primaryHoverType=2,availableHoverTypes=2,primaryPointerType=4,availablePointerTypes=4")
  end

  # Keep the tab and trailing spaces visible in this fixture's source.
  SOURCE = <<~'CODE'.gsub("\\t", "\t").gsub("\\s", " ")
    printf '%s\n' "comillas al final'"
    \t  echo `uname` /tmp/ruta\ con\ espacios "$HOME" && echo '<>& | ñ 😀'
      última línea con espacios\s\s

  CODE

  setup do
    @card = cards(:layout)
    @comment = comments(:layout_overflowing_david)
    @card.update! description: code_block(SOURCE, language: "shell")
    @comment.update! body: "<pre><code>otro bloque\n</code></pre>" + code_block("tercer bloque'")
    Capybara.using_wait_time(10) { sign_in_as(users(:david)) }
    visit card_url(@card)
    page.driver.browser.execute_cdp("Browser.grantPermissions", permissions: %w[ clipboardReadWrite clipboardSanitizedWrite ])
  end

  test "copies each block exactly with the real clipboard and restores its label" do
    blocks = all(".code-block", minimum: 3)
    [ SOURCE, "otro bloque\n", "tercer bloque'" ].zip(blocks).each do |expected, block|
      assert_equal expected, page.evaluate_script("arguments[0].textContent", block.find("pre"))
      button = block.find("button[aria-label='Copiar código']", visible: :all)
      button.hover
      button.click
      assert_equal expected, page.evaluate_async_script("navigator.clipboard.readText().then(arguments[0])")
      within(block) do
        assert_selector "button[aria-label='Copiar código']", text: "Copiado"
        assert_selector "[role=status]", text: "Código copiado"
        assert_selector "button[aria-label='Copiar código']", text: "Copiar", wait: 4
      end
    end
  end

  test "a denied or unavailable clipboard shows an error without success" do
    block = find(".card__description .code-block")
    block.hover
    page.execute_script(<<~JS)
      Object.defineProperty(navigator, "clipboard", { configurable: true, value: {
        writeText: () => Promise.reject(new DOMException("Denied", "NotAllowedError"))
      } })
    JS
    within(block) do
      find("button[aria-label='Copiar código']").click
      assert_selector "[role=status]", text: "No se pudo copiar. Selecciona el código y cópialo manualmente."
      assert_no_selector "button[aria-label='Copiar código']", text: "Copiado"
    end

    page.execute_script('Object.defineProperty(navigator, "clipboard", { configurable: true, value: undefined })')
    within(block) do
      find("button[aria-label='Copiar código']").click
      assert_selector "[role=status]", text: "No se pudo copiar"
      assert_no_selector "button[aria-label='Copiar código']", text: "Copiado"
    end
  end

  test "desktop hover and keyboard focus expose a button that preserves manual selection" do
    block = find(".card__description .code-block")
    button = block.find("button", visible: :all)
    page.execute_script("document.activeElement.blur()")
    page.driver.browser.action.move_to(find("header", match: :first).native).perform
    assert_equal "0", page.evaluate_script("getComputedStyle(arguments[0]).opacity", button)
    block.hover
    assert_equal "1", page.evaluate_script("getComputedStyle(arguments[0]).opacity", button)
    page.driver.browser.action.move_to(find("header", match: :first).native).perform
    page.execute_script("arguments[0].focus()", find(".card__title-link"))
    page.driver.browser.action.send_keys(:tab).perform
    assert page.evaluate_script("document.activeElement === arguments[0]", button)
    assert_equal "1", page.evaluate_script("getComputedStyle(arguments[0]).opacity", button)
    button.send_keys(:enter)
    within(block) { assert_selector "button[aria-label='Copiar código']", text: "Copiado" }

    selection = page.evaluate_script(<<~JS, block.find("pre"))
      (() => {
        const selection = window.getSelection()
        selection.selectAllChildren(arguments[0])
        return selection.toString()
      })()
    JS
    button.click
    assert_equal selection, page.evaluate_script("window.getSelection().toString()")
  end

  test "touch can copy without hover and the control does not cover code" do
    window = Capybara.current_session.current_window
    original_size = window.size
    window.resize_to(390, 844)
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true, maxTouchPoints: 1)
    assert page.evaluate_script("matchMedia('(any-hover: none)').matches")
    block = find(".card__description .code-block")
    scroll_to block, align: :center
    button = block.find("button")
    assert_equal "1", page.evaluate_script("getComputedStyle(arguments[0]).opacity", button)
    rect = page.evaluate_script(<<~JS, button, block.find("pre"))
      (() => {
        const b = arguments[0].getBoundingClientRect(), p = arguments[1].getBoundingClientRect()
        return { x: b.x + b.width / 2, y: b.y + b.height / 2, height: b.height, bottom: b.bottom, top: p.top }
      })()
    JS
    assert_operator rect["height"], :>=, 44
    assert_operator rect["bottom"], :<=, rect["top"]
    page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: "touchStart", touchPoints: [ { x: rect["x"], y: rect["y"] } ])
    page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: "touchEnd", touchPoints: [])
    within(block) { assert_selector "button[aria-label='Copiar código']", text: "Copiado" }
  ensure
    window.resize_to(*original_size)
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
  end

  test "navigation and a live description refresh keep exactly one control per block" do
    assert_selector ".code-block button", count: 3, visible: :all
    page.execute_script("Turbo.visit(arguments[0])", board_url(@card.board))
    assert_no_selector ".card__description"
    page.go_back
    assert_selector ".code-block button", count: 3, visible: :all
    assert_selector "turbo-cable-stream-source[connected]", visible: :all
    assert_no_selector "turbo-cable-stream-source:not([connected])", visible: :all

    Current.user = users(:kevin)
    @card.update! description: code_block("nuevo'\n") + code_block("actualizado\t\n")
    perform_enqueued_jobs only: Turbo::Streams::BroadcastStreamJob

    assert_selector ".card__description pre", text: "nuevo'"
    assert_selector ".card__description .code-block button", count: 2, visible: :all
    assert_selector ".code-block button", count: 4, visible: :all
  end

  test "editing and posting code never saves a copy control or changes the editor selection" do
    click_link "Edit this comment"
    editor = find(".comment:not(.comment--new) lexxy-editor [contenteditable=true]")
    scroll_to editor, align: :center
    editor.click(x: 10, y: 10)
    initial_value = page.evaluate_script("arguments[0].closest('lexxy-editor').value", editor)
    selection = page.evaluate_script(<<~JS)
      (() => {
        const s = window.getSelection()
        return [s.anchorNode.textContent, s.anchorOffset, s.focusNode.textContent, s.focusOffset]
      })()
    JS
    assert_no_selector "lexxy-editor .code-block, lexxy-editor [data-code-copy-button]", visible: :all
    assert_equal initial_value, page.evaluate_script("arguments[0].closest('lexxy-editor').value", editor)
    assert_equal selection, page.evaluate_script("(() => { const s = window.getSelection(); return [s.anchorNode.textContent, s.anchorOffset, s.focusNode.textContent, s.focusOffset] })()")
    click_button "Save"
    assert_selector "#comment_#{@comment.id} .code-block button", count: 2, visible: :all
    assert_no_match(/Copiar|Copiado|code-block/, @comment.reload.body.to_s)

    editor = find(".comment--new lexxy-editor [contenteditable=true]")
    scroll_to editor, align: :center
    editor.click(x: 10, y: 10)
    page.execute_script(<<~JS, editor, "```\necho 'nuevo'\n```")
      const data = new DataTransfer()
      data.setData("text/plain", arguments[1])
      arguments[0].dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }))
    JS
    assert_no_selector "lexxy-editor .code-block, lexxy-editor [data-code-copy-button]", visible: :all
    within(".comment--new form") { click_button "Post" }
    assert_selector ".comment:not(.comment--new) .code-block", text: "echo 'nuevo'"
    assert_no_match(/Copiar|Copiado|code-block/, @card.comments.last.body.to_s)
  end

  # Close after the inherited Trusted Types drain, so device emulation cannot
  # leak into another test and each desktop starts with its real media settings.
  def after_teardown
    super
  ensure
    page.driver.quit
  end

  private
    def code_block(text, language: "plain")
      %(<pre data-language="#{language}">#{ERB::Util.html_escape(text)}</pre>)
    end
end
