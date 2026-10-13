require "application_system_test_case"

class MagicLinkSubmissionTest < ApplicationSystemTestCase
  test "pasting then pressing Enter submits the complete code once after cache deletion" do
    visit new_session_url(script_name: nil)
    fill_in "email_address", with: identities(:kevin).email_address
    click_on "log_in"
    assert_selector "h1", text: "Check your email"

    code = identities(:kevin).magic_links.active.order(:id).last.code
    input = find("#code")

    ready = page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      ;(async () => {
        await caches.open("magic-link-submission-test")
        const originalDelete = caches.delete.bind(caches)
        window.pendingDeletions = []
        caches.delete = name => new Promise(resolve => {
          window.pendingDeletions.push(() => originalDelete(name).then(resolve))
        })
        window.codeRequests = []
        document.querySelector("#code").form.addEventListener("turbo:before-fetch-request", event => {
          window.codeRequests.push(event.detail.fetchOptions.body.get("code"))
          event.preventDefault()
          window.resumeCodeRequest = event.detail.resume
        })
        done(true)
      })().catch(error => done(error.message))
    JS
    assert_equal true, ready

    # A synthetic paste has no default insertion; insert the clipboard value
    # before the controller's next-tick submission, then send a real Enter.
    page.execute_script(<<~JS, input, code)
      const [input, code] = arguments
      const clipboard = new DataTransfer()
      clipboard.setData("text/plain", code)
      input.dispatchEvent(new ClipboardEvent("paste", { clipboardData: clipboard, bubbles: true }))
      input.value = code
    JS
    input.send_keys :enter

    state = page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      setTimeout(() => done({ requests: window.codeRequests, disabled: document.querySelector("#code").disabled,
        pending: window.pendingDeletions.length }), 50)
    JS
    assert_empty state.fetch("requests")
    assert_equal false, state.fetch("disabled")
    assert_equal 1, state.fetch("pending"), "Repeated submit started another cache deletion"

    requests = page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      window.pendingDeletions.forEach(release => release())
      setTimeout(() => done(window.codeRequests), 50)
    JS
    assert_equal [ code ], requests
    page.execute_script("window.resumeCodeRequest()")
    assert_no_selector "#code"
    assert_nil identities(:kevin).magic_links.active.find_by(code: code)
  end

  test "invalid input and a failed deletion allow another submission" do
    visit new_session_url(script_name: nil)

    ready = page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      ;(async () => {
        await caches.open("magic-link-retry-test")
        const originalDelete = caches.delete.bind(caches)
        window.deletionAttempts = 0
        caches.delete = name => {
          window.deletionAttempts++
          if (window.deletionAttempts === 1) return Promise.reject(new Error("Simulated cache deletion failure"))
          return originalDelete(name)
        }
        done(true)
      })().catch(error => done(error.message))
    JS
    assert_equal true, ready

    click_on "log_in"
    assert_equal 0, page.evaluate_script("window.deletionAttempts")

    fill_in "email_address", with: identities(:kevin).email_address
    click_on "log_in"
    attempts = page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      setTimeout(() => done(window.deletionAttempts), 50)
    JS
    assert_equal 1, attempts
    assert_selector "#email_address"

    click_on "log_in"
    assert_selector "h1", text: "Check your email"
  end
end
