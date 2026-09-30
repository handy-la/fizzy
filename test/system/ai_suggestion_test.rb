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
    fill_in_lexxy with: "<p>El recibo no muestra el total.</p>"
    page.execute_script('document.querySelector("lexxy-editor").dispatchEvent(new CustomEvent("lexxy:change", { bubbles: true }))')
    wait_for_request
    assert_equal "title", page.evaluate_script("window.suggestionRequests[0].kind")
    respond_with "Corregir total del recibo"
    assert_field "card_title", with: "Corregir total del recibo"
    find("#card_title").set("Mi título")
    find("lexxy-editor").click
    assert_field "card_title", with: "Mi título"
    Timeout.timeout(5) do
      sleep 0.05 until draft.reload.title == "Mi título"
    end
    assert draft.drafted?
  end

  test "comment is requested only when visible and remains an unpublished editable draft" do
    visit card_url(@card)
    control_suggestions
    assert_equal 0, page.evaluate_script("window.suggestionRequests.length")
    scroll_to_comment
    wait_for_request
    count = @card.comments.count
    respond_with "¿Puedes confirmar el resultado? <script>alert(1)</script>"
    assert_selector ".comment--new lexxy-editor", text: "¿Puedes confirmar el resultado?"
    assert_no_selector ".comment--new lexxy-editor script", visible: :all
    assert_equal count, @card.reload.comments.count
    within(".comment--new") { assert_button "Post", disabled: false }
  end

  test "a late reply cannot replace text typed and then cleared" do
    visit card_url(@card)
    control_suggestions
    scroll_to_comment
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
    assert_selector ".comment--new lexxy-editor", text: "Mi borrador guardado"
    assert_equal 0, page.evaluate_script("window.suggestionRequests.length")
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

    def wait_for_request
      assert_selector "body"
      Timeout.timeout(5) do
        sleep 0.05 until page.evaluate_script("window.suggestionRequests.length > 0")
      end
    end

    def respond_with(text)
      page.evaluate_async_script(<<~JS, text)
        const text = arguments[0], done = arguments[arguments.length - 1]
        window.resolveSuggestion(new Response(JSON.stringify({ suggestion: text }), {
          headers: { "Content-Type": "application/json" }, status: 200
        }))
        setTimeout(done, 100)
      JS
    end

    def scroll_to_comment
      page.execute_script('document.querySelector(".comment--new lexxy-editor").scrollIntoView()')
    end
end
