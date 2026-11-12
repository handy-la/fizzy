require "application_system_test_case"

# Handy #2341: después de publicar un comentario, el siguiente publicaba otra
# vez el anterior y perdía el texto nuevo. Ficha de pruebas y evidencia RED:
# docs/test-audits/handy-2341.md.
class CommentSubmissionTest < ApplicationSystemTestCase
  setup do
    sign_in_as(users(:david))
    @card = cards(:layout)
    @existing_comment_ids = @card.comments.ids
    visit card_url(@card)
    record_submitted_bodies
  end

  # Capybara reuses the browser: a draft left here would appear in the next test's
  # editor. Teardown callbacks run after Capybara resets the page, so this goes first.
  def before_teardown
    page.execute_script("localStorage.removeItem(arguments[0])", draft_key)
  ensure
    super
  end

  test "consecutive comments are each saved once with their own text while the card refreshes" do
    # Each comment is typed in parts with a pause between them, so the draft saved
    # during the pause is older than what the editor shows when the refresh arrives.
    comments = [
      [ [ [ "Primer comentario A" ] ], "Primer comentario A" ],
      [ [ [ "Segundo B: línea uno" ], [ :enter, "línea dos" ] ], "Segundo B: línea uno\nlínea dos" ],
      [ [ [ "Tercero C <b>&amp;" ], [ %( "comillas" 'ñ' €) ] ], %(Tercero C <b>&amp; "comillas" 'ñ' €) ]
    ]

    comments.each_with_index do |(parts, text), index|
      reply = "Respuesta de otra persona #{index}"
      comment_elsewhere(reply) unless index.zero?
      editor = focus_editor
      parts.each_with_index do |keys, part|
        wait_past_draft_save unless part.zero?
        editor.send_keys(*keys)
      end

      unless index.zero?
        refresh_card(showing: reply)
        wait_past_draft_save
        assert_equal text.split("\n"), editor_lines
      end
      post_now

      assert_selector ".comment:not(.comment--new) .lexxy-content", text: text.split("\n").last
      assert_equal comments.first(index + 1).map(&:last), new_comments.map { plain_text(it) }
      assert_equal text, plain_text_of(submitted_bodies.last)

      wait_past_draft_save
    end
  end

  test "a sent comment does not come back as a draft after leaving and returning to the card" do
    # The pause saves "Comentario ya" as the draft; the quick post comes before " enviado" is saved.
    type_and_post([ "Comentario ya" ], [ " enviado" ])
    assert_selector ".comment:not(.comment--new) .lexxy-content", text: "Comentario ya enviado"
    wait_past_draft_save

    assert_nil saved_draft

    visit board_url(@card.board)
    visit card_url(@card)

    assert_selector ".comment--new lexxy-editor[connected]"
    wait_past_draft_save
    assert_equal [], editor_lines
    assert_nil saved_draft
  end

  test "text typed while the previous comment is sending stays as the next draft" do
    delay_comment_requests_by 1.5
    focus_editor.send_keys("Comentario enviado")
    within(".comment--new form") { click_button "Post" }

    focus_editor.send_keys(:enter, "Texto nuevo")
    assert_selector ".comment:not(.comment--new) .lexxy-content", text: "Comentario enviado"

    assert_equal [ "Comentario enviado" ], new_comments.map { plain_text(it) }
    assert_equal [ "Comentario enviado", "Texto nuevo" ], editor_lines
    assert_includes saved_draft, "Texto nuevo"
  end

  test "text added and removed while the comment is sending does not come back" do
    hold_comment_requests
    focus_editor.send_keys("Comentario enviado")
    within(".comment--new form") { click_button "Post" }

    focus_editor.send_keys(" y borrado")
    wait_past_draft_save
    assert_includes saved_draft, "y borrado"
    focus_editor.send_keys(*([ :backspace ] * " y borrado".length))
    release_comment_requests
    assert_selector ".comment:not(.comment--new) .lexxy-content", text: "Comentario enviado"

    wait_past_draft_save
    assert_equal [ "Comentario enviado" ], new_comments.map { plain_text(it) }
    assert_equal [], editor_lines
    assert_nil saved_draft
  end

  test "a network error keeps the draft and adds no comment" do
    fail_comment_requests
    focus_editor.send_keys("Borrador sin red")
    within(".comment--new form") { click_button "Post" }

    assert_selector ".comment--new form:not([aria-busy])"
    wait_past_draft_save
    assert_equal [ "Borrador sin red" ], editor_lines
    assert_includes saved_draft, "Borrador sin red"
    assert_no_selector ".comment:not(.comment--new) .lexxy-content", text: "Borrador sin red"
    assert_empty new_comments
  end

  test "a rejected comment keeps the draft and adds no comment" do
    focus_editor.send_keys("Borrador rechazado")
    @card.update_column(:status, "drafted")
    within(".comment--new form") { click_button "Post" }

    assert_selector ".comment--new form:not([aria-busy])"
    wait_past_draft_save
    assert_equal [ "Borrador rechazado" ], editor_lines
    assert_includes saved_draft, "Borrador rechazado"
    assert_no_selector ".comment:not(.comment--new) .lexxy-content", text: "Borrador rechazado"
    assert_empty new_comments
  end

  private
    def focus_editor(selector = ".comment--new lexxy-editor [contenteditable='true']")
      editor = find(selector)
      scroll_to editor, align: :center
      editor.click(x: 10, y: 10)
      assert_selector "#{selector}:focus"
      editor
    end

    def comment_elsewhere(text)
      Current.set(user: users(:kevin)) { @card.comments.create!(body: text) }
    end

    # Cable delivers a card's refresh as this same <turbo-stream action="refresh">. It is
    # inserted here, right after the last key, so it arrives while that key's draft save
    # is still pending; a broadcast's timing cannot be held to that window.
    def refresh_card(showing:)
      page.execute_script(<<~JS)
        window.__morphed = false
        document.addEventListener("turbo:morph", () => window.__morphed = true, { once: true })
        document.body.insertAdjacentHTML("beforeend", '<turbo-stream action="refresh"></turbo-stream>')
      JS

      assert_selector ".comment:not(.comment--new) .lexxy-content", text: showing
      assert page.evaluate_async_script(<<~JS), "the card did not refresh"
        const done = arguments[0]
        const started = Date.now()
        const check = () => window.__morphed ? requestAnimationFrame(() => requestAnimationFrame(() => done(true))) : (Date.now() - started > 5000 ? done(false) : setTimeout(check, 20))
        check()
      JS
    end

    # Presses Post two frames after the last key, as a quick tap does: the request can
    # end before the draft save of that key runs, 300 ms after it.
    def type_and_post(*parts)
      editor = focus_editor
      parts.each_with_index do |keys, part|
        wait_past_draft_save unless part.zero?
        editor.send_keys(*keys)
      end
      post_now
    end

    def post_now
      page.evaluate_async_script(<<~JS)
        const done = arguments[0]
        requestAnimationFrame(() => requestAnimationFrame(() => {
          document.querySelector(".comment--new .comment__submit").click()
          done(true)
        }))
      JS
    end

    # The local draft is saved 300 ms after the last change.
    def wait_past_draft_save
      sleep 0.5
    end

    def editor_lines
      find(".comment--new lexxy-editor .lexxy-editor__content").all("p", minimum: 0).map(&:text).reject(&:empty?)
    end

    def saved_draft
      page.evaluate_script("localStorage.getItem(arguments[0])", draft_key)
    end

    # Handy #2304: the draft is kept per person and card.
    def draft_key
      "comment-#{users(:david).id}-#{@card.id}"
    end

    def record_submitted_bodies
      page.execute_script(<<~JS)
        window.__submittedBodies = []
        document.addEventListener("turbo:submit-start", (event) => {
          const body = event.detail.formSubmission.fetchRequest.body
          const text = body?.get?.("comment[body]")
          if (text != null) window.__submittedBodies.push(text)
        })
      JS
    end

    def submitted_bodies
      page.evaluate_script("window.__submittedBodies")
    end

    def delay_comment_requests_by(seconds)
      wrap_comment_requests "new Promise((resolve) => setTimeout(resolve, #{(seconds * 1000).to_i})).then(() => original(input, init))"
    end

    # The request waits until the test releases it, so the response can arrive while
    # the draft save of the last key is still pending.
    def hold_comment_requests
      page.execute_script("window.__commentRequestsHeld = new Promise((resolve) => window.__releaseCommentRequests = resolve)")
      wrap_comment_requests "window.__commentRequestsHeld.then(() => original(input, init))"
    end

    def release_comment_requests
      page.execute_script("window.__releaseCommentRequests()")
    end

    def fail_comment_requests
      wrap_comment_requests "Promise.reject(new TypeError('Failed to fetch'))"
    end

    def wrap_comment_requests(expression)
      page.execute_script(<<~JS)
        const original = window.fetch
        window.fetch = (input, init) => {
          const url = typeof input === "string" ? input : input.url
          return init?.method?.toUpperCase() === "POST" && url.includes("/comments") ? #{expression} : original(input, init)
        }
      JS
    end

    def new_comments
      @card.comments.where(creator: users(:david)).where.not(id: @existing_comment_ids).order(:created_at)
    end

    def plain_text(comment)
      lines_of comment.body.to_plain_text
    end

    def plain_text_of(html)
      lines_of ActionText::Content.new(html).to_plain_text
    end

    def lines_of(text)
      text.lines.map(&:strip).reject(&:empty?).join("\n")
    end
end
