require "application_system_test_case"

class AiSuggestionSystemTest < ApplicationSystemTestCase
  setup do
    sign_in_as(users(:david))
    @card = cards(:layout)
    @card.update!(description: Array.new(80, "Contexto de la tarjeta.").join("\n\n"))
  end

  test "title is suggested after typing stops and saved as an editable draft" do
    draft = boards(:writebook).cards.create!(status: :drafted, creator: users(:david))
    visit card_draft_url(draft)
    control_suggestions
    page.execute_script(<<~JS)
      window.titleMorphs = 0
      document.addEventListener("turbo:morph-element", event => {
        if (event.target.id === "card_title") window.titleMorphs++
      })
    JS
    find("lexxy-editor [contenteditable]").click
    find("lexxy-editor [contenteditable]").send_keys("Corto")
    page.evaluate_async_script("setTimeout(arguments[arguments.length - 1], 1600)")
    assert_equal 0, page.evaluate_script("window.suggestionRequests.length")
    assert_selector '#card_title[placeholder="Name it…"]'
    find("lexxy-editor [contenteditable]").send_keys(" El recibo no muestra el total.")
    wait_for_request
    assert_selector '#card_title[placeholder="Sugiriendo título..."]'
    assert_field "card_title", with: ""
    assert_equal "title", page.evaluate_script("window.suggestionRequests[0].kind")
    page.execute_script('document.querySelector("#card_form").requestSubmit()')
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script("window.titleMorphs > 0")
    end
    assert_selector '#card_title[placeholder="Sugiriendo título..."]'
    respond_with "Corregir total del recibo"
    assert_field "card_title", with: "Corregir total del recibo"
    assert_selector '#card_title[placeholder="Name it…"]'
    find("#card_title").set("Mi título")
    find("lexxy-editor").click
    assert_field "card_title", with: "Mi título"
    Timeout.timeout(5) do
      sleep 0.05 until draft.reload.title == "Mi título"
    end
    assert draft.drafted?
  end

  # Handy #588: dictation apps paste the description. Lexical consumes the
  # paste event, so no beforeinput reaches the controller. Contract and RED:
  # docs/test-audits/handy-588.md.
  test "pasting a long description suggests the title" do
    draft = boards(:writebook).cards.create!(status: :drafted, creator: users(:david))
    visit card_draft_url(draft)
    control_suggestions
    page.driver.browser.execute_cdp("Browser.grantPermissions", permissions: %w[ clipboardReadWrite clipboardSanitizedWrite ])
    editor = find("lexxy-editor [contenteditable]")
    editor.click
    page.evaluate_async_script(<<~JS, "El recibo de la venta no muestra el total cuando hay descuento.")
      navigator.clipboard.writeText(arguments[0]).then(arguments[arguments.length - 1])
    JS
    editor.send_keys([ :control, "v" ])
    assert_selector "lexxy-editor", text: "El recibo de la venta no muestra el total"
    wait_for_request
    assert_equal "title", page.evaluate_script("window.suggestionRequests[0].kind")
    respond_with "Mostrar total con descuento en el recibo"
    assert_field "card_title", with: "Mostrar total con descuento en el recibo"
  end

  test "title waiting placeholder is restored on failure cancellation and disconnection" do
    %w[ failed skipped title description disconnect ].each do |outcome|
      draft = boards(:writebook).cards.create!(status: :drafted, creator: users(:david))
      visit card_draft_url(draft)
      control_suggestions
      find("lexxy-editor [contenteditable]").click
      find("lexxy-editor [contenteditable]").send_keys("El recibo no muestra el total de la venta.")
      wait_for_request
      assert_selector '#card_title[placeholder="Sugiriendo título..."]'

      case outcome
      when "failed"
        respond_with nil, status: "failed"
      when "skipped"
        page.execute_script("window.resolveSuggestion(new Response(null, { status: 204 }))")
      when "title"
        find("#card_title").set("Mi título")
      when "description"
        find("lexxy-editor [contenteditable]").send_keys(" Otra observación.")
      when "disconnect"
        page.execute_script('document.querySelector("#card_form").dataset.controller = "autoresize auto-save"')
      end

      assert_selector '#card_title[placeholder="Name it…"]'
    end
  end

  test "title waiting placeholder lasts through pending and running Cable states" do
    previous_key = RubyLLM.config.openai_api_key
    previous_cable = ActionCable.server.config.cable
    RubyLLM.config.openai_api_key = "test-key"
    ActionCable.server.config.cable = { "adapter" => "async" }
    ActionCable.server.restart
    draft = boards(:writebook).cards.create!(status: :drafted, creator: users(:david))
    visit card_draft_url(draft)
    page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1]
      import("@hotwired/turbo-rails").then(({ cable }) => cable.getConsumer()).then(consumer => {
        consumer.ensureActiveConnection()
        window.titleSuggestionStates = []
        consumer.connection.webSocket.addEventListener("message", event => {
          const message = JSON.parse(event.data).message
          if (message?.status) window.titleSuggestionStates.push(message.status)
        })
        done()
      })
    JS
    find("lexxy-editor [contenteditable]").click
    find("lexxy-editor [contenteditable]").send_keys("El recibo no muestra el total de la venta.")
    request = nil
    Timeout.timeout(5) do
      sleep 0.05 until request = Card::SuggestionRequest.find_by(card: draft, kind: "title")
    end
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script("window.titleSuggestionStates.includes('pending')")
    end
    assert_selector '#card_title[placeholder="Sugiriendo título..."]'
    assert_field "card_title", with: ""
    request.update!(status: "running", started_at: Time.current)
    ActionCable.server.broadcast(request.stream_name, { request_id: request.token })
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script("window.titleSuggestionStates.includes('running')")
    end
    assert_selector '#card_title[placeholder="Sugiriendo título..."]'
    request.update!(status: "failed", error_category: "provider")
    ActionCable.server.broadcast(request.stream_name, { request_id: request.token })
    assert_selector '#card_title[placeholder="Name it…"]'
    assert_field "card_title", with: ""
  ensure
    RubyLLM.config.openai_api_key = previous_key
    ActionCable.server.config.cable = previous_cable
    ActionCable.server.restart
  end

  test "comment stays a placeholder until Enter accepts it without posting" do
    visit card_url(@card)
    control_suggestions
    assert_equal 0, page.evaluate_script("window.suggestionRequests.length")
    scroll_to_comment
    page.execute_script('document.querySelector(".comment--new [contenteditable]").focus()')
    page.execute_script('document.querySelector(".comment--new [contenteditable]").blur()')
    page.execute_script('document.querySelector(".comment--new lexxy-editor").dispatchEvent(new CustomEvent("lexxy:change", { bubbles: true }))')
    assert_equal 0, page.evaluate_script("window.suggestionRequests.length")
    find(".comment--new lexxy-editor [contenteditable]").click
    wait_for_request
    assert_selector '.comment--new lexxy-editor[placeholder="Preparando sugerencia…"]'
    assert_selector '.comment--new [contenteditable][placeholder="Preparando sugerencia…"]'
    assert_waiting_announced_off_screen
    within(".comment--new") { assert_button "Post", disabled: true }
    find(".comment--new button[title=Bold]").click
    find(".comment--new lexxy-editor [contenteditable]").click
    assert_equal 1, page.evaluate_script("window.suggestionRequests.length")
    count = @card.comments.count
    empty_value = page.evaluate_script('document.querySelector(".comment--new lexxy-editor").value')
    respond_with "¿Puedes confirmar el resultado? <script>alert(1)</script>"
    assert_selector '.comment--new [contenteditable][placeholder*="Enter para aceptar"]'
    assert_equal empty_value, page.evaluate_script('document.querySelector(".comment--new lexxy-editor").value')
    # Beyond local-save's debounce; empty Lexxy markup is not a draft either.
    page.evaluate_async_script("setTimeout(arguments[arguments.length - 1], 500)")
    assert_nil page.evaluate_script("localStorage.getItem('comment-#{@card.id}')")
    within(".comment--new") { assert_button "Post", disabled: true }
    find(".comment--new lexxy-editor [contenteditable]").send_keys(:enter)
    assert_selector ".comment--new lexxy-editor", text: "¿Puedes confirmar el resultado?"
    assert_no_selector ".comment--new lexxy-editor script", visible: :all
    assert_equal count, @card.reload.comments.count
    find(".comment--new button[title=Bold]").click
    find(".comment--new lexxy-editor [contenteditable]").click
    assert_equal 1, page.evaluate_script("window.suggestionRequests.length")
    within(".comment--new") { assert_button "Post", disabled: false }
  end

  # Contrato y evidencia RED: docs/test-audits/handy-631.md.
  test "comment waiting placeholder is restored on failure cancellation and disconnection" do
    %w[ failed skipped typing disconnect ].each do |outcome|
      visit card_url(@card)
      page.execute_script("sessionStorage.clear(); localStorage.clear()")
      control_suggestions
      scroll_to_comment
      original = find(".comment--new lexxy-editor")["placeholder"]
      find(".comment--new [contenteditable]").click
      wait_for_request
      assert_selector '.comment--new [contenteditable][placeholder="Preparando sugerencia…"]'
      assert_waiting_announced_off_screen

      case outcome
      when "failed"
        respond_with nil, status: "failed"
        assert_selector '[data-ai-suggestion-target="status"]', text: "No se pudo obtener la sugerencia."
        assert_operator comment_status[:width], :>, 1
        assert_button "Reintentar sugerencia"
      when "skipped"
        page.execute_script("window.resolveSuggestion(new Response(null, { status: 204 }))")
      when "typing"
        find(".comment--new [contenteditable]").send_keys("Mi respuesta")
        respond_with "Respuesta tardía"
        assert_selector ".comment--new lexxy-editor", text: "Mi respuesta"
      when "disconnect"
        page.execute_script('document.querySelector(".comment--new form").dataset.controller = "form local-save"')
      end

      assert_selector ".comment--new lexxy-editor[placeholder=#{original.to_json}]"
      assert_selector ".comment--new [contenteditable][placeholder=#{original.to_json}]"
      assert_not_includes comment_status[:text], "Preparando sugerencia", outcome
    end
  end

  # Handy #571: on a phone, pointerdown fires on touchstart, but focus arrives
  # only after the finger lifts. Contract and RED: docs/test-audits/handy-571.md.
  test "a touch tap on the empty comment requests one suggestion" do
    visit card_url(@card)
    control_suggestions
    scroll_to_comment
    page.execute_script(<<~JS)
      const editor = document.querySelector(".comment--new [contenteditable]")
      editor.focus()
      editor.dispatchEvent(new MouseEvent("click", { bubbles: true }))
      editor.blur()
    JS
    assert_equal 0, page.evaluate_script("window.suggestionRequests.length")
    editor = find(".comment--new lexxy-editor [contenteditable]").native
    finger = Selenium::WebDriver::Interactions.pointer(:touch, name: "finger")
    page.driver.browser.action(devices: [ finger ])
      .move_to(editor, device: "finger").pointer_down(:left, device: "finger")
      .pause(device: finger, duration: 0.15).pointer_up(:left, device: "finger").perform
    wait_for_request
    assert_selector '.comment--new [contenteditable][placeholder="Preparando sugerencia…"]'
    page.evaluate_async_script("setTimeout(arguments[arguments.length - 1], 250)")
    assert_equal 1, page.evaluate_script("window.suggestionRequests.length")
  end

  test "a late reply cannot replace text typed and then cleared" do
    visit card_url(@card)
    control_suggestions
    scroll_to_comment
    assert_equal 0, page.evaluate_script("window.suggestionRequests.length")
    find(".comment--new lexxy-editor [contenteditable]").click
    wait_for_request
    page.execute_script(<<~JS)
      const editor = document.querySelector(".comment--new lexxy-editor")
      editor.value = "<p>Mi respuesta</p>"
      editor.dispatchEvent(new CustomEvent("lexxy:change", { bubbles: true }))
      editor.value = ""
      editor.dispatchEvent(new CustomEvent("lexxy:change", { bubbles: true }))
    JS
    respond_with "Respuesta tardía"
    assert_no_selector ".comment--new lexxy-editor", text: "Respuesta tardía"
    assert_equal "", page.evaluate_script('document.querySelector(".comment--new lexxy-editor [contenteditable]").textContent.trim()')
  end

  test "a locally saved comment survives entering the editor" do
    visit card_url(@card)
    page.execute_script("localStorage.setItem(arguments[0], '<p>Mi borrador guardado</p>')", "comment-#{@card.id}")
    visit card_url(@card)
    control_suggestions
    scroll_to_comment
    find(".comment--new lexxy-editor [contenteditable]").click
    assert_selector ".comment--new lexxy-editor", text: "Mi borrador guardado"
    assert_equal 0, page.evaluate_script("window.suggestionRequests.length")
  end

  test "a terminal failure remains retryable after form reconnection" do
    visit card_url(@card)
    control_suggestions
    scroll_to_comment
    find(".comment--new [contenteditable]").click
    wait_for_request
    respond_with nil, status: "failed", request_id: "failed-request"
    assert_button "Reintentar sugerencia"
    page.execute_script('document.querySelector(".comment--new form").dataset.controller = "form local-save"')
    page.evaluate_async_script("setTimeout(arguments[arguments.length - 1], 100)")
    page.execute_script('document.querySelector(".comment--new form").dataset.controller = "form local-save ai-suggestion"')
    click_button "Reintentar sugerencia"
    assert_equal 2, page.evaluate_script("window.suggestionRequests.length")
    respond_with "Sí, adelante."
    assert_selector '.comment--new [contenteditable][placeholder*="Enter para aceptar"]'
  end

  test "restored description and synthetic events do not request a title" do
    draft = boards(:writebook).cards.create!(status: :drafted, creator: users(:david))
    visit card_draft_url(draft)
    control_suggestions
    page.execute_script(<<~JS)
      const editor = document.querySelector("lexxy-editor")
      editor.value = "<p>Descripción restaurada con contenido suficiente.</p>"
      editor.dispatchEvent(new CustomEvent("lexxy:change", { bubbles: true }))
      editor.dispatchEvent(new Event("input", { bubbles: true }))
    JS
    # A scripted paste is inserted by Lexical but is not the person's intent.
    find("lexxy-editor [contenteditable]").click(x: 10, y: 10)
    page.execute_script(<<~JS)
      const editable = document.querySelector("lexxy-editor [contenteditable]")
      const data = new DataTransfer()
      data.setData("text/plain", " Texto pegado por un script.")
      editable.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }))
    JS
    assert_selector "lexxy-editor", text: "Texto pegado por un script."
    # Beyond the production debounce: absence of requests is the contract.
    page.evaluate_async_script("setTimeout(arguments[arguments.length - 1], 1600)")
    assert_equal 0, page.evaluate_script("window.suggestionRequests.length")
  end

  test "keyboard focus can recover an interrupted POST after form reconnection" do
    visit card_url(@card)
    control_suggestions
    scroll_to_comment
    # Native Tab navigation from the last toolbar button into the editable field.
    editor = find(".comment--new lexxy-editor [contenteditable]")
    page.execute_script("arguments[0].focus()", editor)
    assert_equal 0, page.evaluate_script("window.suggestionRequests.length")
    editor.send_keys([ :shift, :tab ])
    page.driver.browser.switch_to.active_element.send_keys(:tab)
    wait_for_request
    page.execute_script(<<~JS)
      document.querySelector(".comment--new form").dataset.controller = "form local-save"
    JS
    page.evaluate_async_script("setTimeout(arguments[arguments.length - 1], 250)")
    page.execute_script('document.querySelector(".comment--new form").dataset.controller = "form local-save ai-suggestion"')
    scroll_to_comment
    page.execute_script('document.querySelector(".comment--new [contenteditable]").blur()')
    find(".comment--new lexxy-editor [contenteditable]").click
    assert_equal 2, page.evaluate_script("window.suggestionRequests.length")
  end

  test "Cable delivers and recovers a real request without another generation" do
    previous_key = RubyLLM.config.openai_api_key
    previous_cable = ActionCable.server.config.cable
    RubyLLM.config.openai_api_key = "test-key"
    ActionCable.server.config.cable = { "adapter" => "async" }
    ActionCable.server.restart
    stub_request(:post, "https://api.fireworks.ai/inference/v1/chat/completions")
      .to_return(headers: { "Content-Type" => "application/json" }, body: {
        id: "suggestion", object: "chat.completion", model: RubyLLM.config.default_model,
        choices: [ { index: 0, message: { role: "assistant", content: "Sí, apruebo la propuesta." }, finish_reason: "stop" } ],
        usage: { prompt_tokens: 10, completion_tokens: 10, total_tokens: 20 }
      }.to_json)
    visit card_url(@card)
    page.execute_script(<<~JS)
      window.suggestionRequests = []
      const originalFetch = window.fetch
      window.fetch = function(url, options) {
        if (String(url).endsWith("/suggestion") && options?.method === "POST") window.suggestionRequests.push(JSON.parse(options.body))
        return originalFetch.call(this, url, options)
      }
    JS
    scroll_to_comment
    find(".comment--new [contenteditable]").click
    assert_selector '.comment--new [contenteditable][placeholder="Preparando sugerencia…"]'
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script("Object.keys(sessionStorage).some(key => key.startsWith('ai-suggestion:') && JSON.parse(sessionStorage.getItem(key))?.token)")
    end
    perform_enqueued_jobs only: Card::SuggestionJob
    assert_selector '.comment--new [contenteditable][placeholder*="Sí, apruebo la propuesta."]'
    page.execute_script(<<~JS)
      import("@hotwired/turbo-rails").then(async ({ cable }) => {
        const consumer = await cable.getConsumer()
        consumer.disconnect()
        document.querySelector(".comment--new form").dataset.controller = "form local-save"
        window.suggestionConsumer = consumer
      })
    JS
    assert_no_selector '.comment--new [contenteditable][placeholder*="Enter para aceptar"]'
    page.execute_script(<<~JS)
        document.querySelector(".comment--new form").dataset.controller = "form local-save ai-suggestion"
        const consumer = window.suggestionConsumer
        consumer.connect()
    JS
    assert_selector '.comment--new [contenteditable][placeholder*="Enter para aceptar"]'
    assert_equal 1, page.evaluate_script("window.suggestionRequests.length")
    assert_requested :post, "https://api.fireworks.ai/inference/v1/chat/completions", times: 1
    find(".comment--new [contenteditable]").send_keys(:enter)
    assert_selector ".comment--new lexxy-editor", text: "Sí, apruebo la propuesta."
  ensure
    RubyLLM.config.openai_api_key = previous_key
    ActionCable.server.config.cable = previous_cable
    ActionCable.server.restart
  end

  test "IME and Shift do not accept, and Ctrl Enter still posts accepted text" do
    visit card_url(@card)
    control_suggestions
    scroll_to_comment
    editor = find(".comment--new [contenteditable]")
    editor.click
    wait_for_request
    respond_with "Sí, adelante."
    assert_selector '.comment--new [contenteditable][placeholder*="Enter para aceptar"]'
    editor.click
    page.execute_script(<<~JS)
      const editor = document.querySelector(".comment--new [contenteditable]")
      // Isolate the AI capture handler: Lexxy must not insert its own composing
      // marker, which would mask acceptance by making the field nonempty.
      for (const type of [ "compositionstart", "compositionend" ]) {
        editor.addEventListener(type, event => event.stopImmediatePropagation(), { capture: true, once: true })
      }
      editor.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true }))
    JS
    editor.send_keys(:enter)
    page.execute_script('document.querySelector(".comment--new [contenteditable]").dispatchEvent(new CompositionEvent("compositionend", { bubbles: true }))')
    assert_no_selector ".comment--new lexxy-editor", text: "Sí, adelante."
    editor.send_keys([ :shift, :enter ])
    assert_no_selector ".comment--new lexxy-editor", text: "Sí, adelante."
    # Shift may insert a blank line, invalidating the proposal. Refocus a fresh form.
    visit card_url(@card)
    page.execute_script("sessionStorage.clear(); localStorage.clear()")
    control_suggestions
    scroll_to_comment
    editor = find(".comment--new [contenteditable]")
    editor.click
    wait_for_request
    respond_with "Sí, adelante."
    editor.send_keys(:enter)
    assert_selector ".comment--new lexxy-editor", text: "Sí, adelante."
    count = @card.comments.count
    editor.send_keys([ :control, :enter ])
    assert_selector ".comment:not(.comment--new)", text: "Sí, adelante."
    assert_equal count + 1, @card.reload.comments.count
  end

  private
    def control_suggestions
      page.execute_script(<<~JS)
        window.suggestionRequests = []
        const originalFetch = window.fetch
        window.fetch = function(url, options) {
          if (String(url).endsWith("/suggestion")) {
            window.suggestionRequests.push(JSON.parse(options.body))
            return new Promise(resolve => { window.resolveSuggestion = resolve })
          }
          return originalFetch.call(this, url, options)
        }
      JS
    end

    # Handy #634 (contract and RED: docs/test-audits/handy-634.md): the wait
    # lives in the placeholder on screen, while the live region keeps the text
    # for screen readers without adding a visible line.
    def assert_waiting_announced_off_screen
      status = comment_status
      assert_equal [ false, "status", "Preparando sugerencia…" ], status.values_at(:hidden, :role, :text)
      assert_operator status[:width], :<=, 1
      assert_operator status[:height], :<=, 1
    end

    def comment_status
      page.evaluate_script(<<~JS).symbolize_keys
        (() => {
          const status = document.querySelector('.comment--new [data-ai-suggestion-target="status"]')
          const box = status.getBoundingClientRect()
          return { hidden: status.hidden, role: status.getAttribute("role"), text: status.textContent, width: box.width, height: box.height }
        })()
      JS
    end

    def wait_for_request
      assert_selector "body"
      Timeout.timeout(5) do
        sleep 0.05 until page.evaluate_script("window.suggestionRequests.length > 0")
      end
    end

    def respond_with(text, status: "completed", request_id: nil)
      page.evaluate_async_script(<<~JS, text, status, request_id)
        const text = arguments[0], status = arguments[1], request_id = arguments[2], done = arguments[arguments.length - 1]
        window.resolveSuggestion(new Response(JSON.stringify({ suggestion: text, status, request_id, expires_at: new Date(Date.now() + 900000).toISOString() }), {
          headers: { "Content-Type": "application/json" }, status: 200
        }))
        setTimeout(done, 100)
      JS
    end

    def scroll_to_comment
      page.execute_script('document.querySelector(".comment--new lexxy-editor").scrollIntoView()')
      page.evaluate_async_script("setTimeout(arguments[arguments.length - 1], 250)")
    end
end
