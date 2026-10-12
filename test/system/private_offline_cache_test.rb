require "application_system_test_case"

class PrivateOfflineCacheTest < ApplicationSystemTestCase
  setup do
    @previous_app_host = Capybara.app_host
    @previous_url_options = default_url_options.dup
    visit new_session_path(script_name: nil)
    # Bind Puma to loopback, but use a domain for WebAuthn in the browser.
    port = Capybara.current_session.server.port
    Capybara.app_host = "http://localhost:#{port}"
    self.default_url_options = default_url_options.merge(host: "localhost", port: port)
  end

  def before_teardown
    set_offline false
    @worker_sessions&.each_value do |session_id|
      page.driver.browser.execute_cdp("Target.detachFromTarget", sessionId: session_id)
    end
    @authenticator&.remove!
    page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      if (!navigator.serviceWorker) { done(); return }
      Promise.all([
        navigator.serviceWorker.getRegistrations().then(registrations => Promise.all(registrations.map(registration => registration.unregister()))),
        caches.keys().then(names => Promise.all(names.map(name => caches.delete(name))))
      ]).then(() => done())
    JS
  ensure
    Capybara.app_host = @previous_app_host
    self.default_url_options = @previous_url_options
    super
  end

  test "revoking a session cannot expose a card or attachment offline" do
    card = cards(:logo)
    Current.session = sessions(:david)
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("private attachment"), filename: "private.txt", content_type: "text/plain")
    card.image.attach(blob)
    sign_in_as users(:david)
    wait_for_worker

    card_url = card_path(card)
    blob_url = rails_storage_proxy_path(blob)
    assert_includes fetch_body(card_url), "big enough"
    assert_equal "private attachment", fetch_body(blob_url)

    # Revocation is server-side: the browser has not seen a login page yet.
    Session.delete_all
    set_offline true

    assert_equal "network unavailable", fetch_body(card_url)
    assert_equal "network unavailable", fetch_body(blob_url)
  end

  test "login and Turbo identity changes remove legacy private responses" do
    sign_in_as users(:david)
    wait_for_worker
    seed_legacy_caches

    Session.delete_all
    page.driver.browser.manage.delete_all_cookies
    visit new_session_path(script_name: nil)
    assert_selector "#log_in"
    assert_no_legacy_caches

    sign_in_as users(:kevin)
    seed_legacy_caches
    # Turbo replaces the current-user meta tag without re-running ES modules.
    page.execute_script(<<~JS)
      document.querySelector('meta[name="current-user-id"]').content = "another-user"
      document.dispatchEvent(new Event("turbo:load"))
    JS
    assert_no_legacy_caches
  end

  test "logout removes legacy caches while public assets still work offline" do
    sign_in_as users(:david)
    wait_for_worker
    asset_url = page.evaluate_script("document.querySelector('link[rel=stylesheet]').href")
    asset_body = fetch_body(asset_url)
    assert_not_equal "network unavailable", asset_body
    assert_not_empty asset_body
    set_offline true
    assert_equal asset_body, fetch_body(asset_url)
    set_offline false

    visit user_path(users(:david))
    seed_legacy_caches
    click_button "Sign out"
    assert_selector "#log_in"
    assert_no_legacy_caches
  end

  test "passkey login clears the previous user's caches before submitting" do
    options = Selenium::WebDriver::VirtualAuthenticatorOptions.new(
      protocol: :ctap2, transport: :internal, resident_key: true,
      user_verification: true, user_verified: true
    )
    @authenticator = page.driver.browser.add_virtual_authenticator(options)
    sign_in_as users(:kevin)
    visit my_passkeys_path
    click_button "Register a passkey"
    assert_text "Your passkey has been registered."
    credentials = @authenticator.credentials
    @authenticator.remove!
    @authenticator = nil

    page.driver.browser.manage.delete_all_cookies
    sign_in_as users(:david)
    wait_for_worker
    Session.delete_all
    visit new_session_path(script_name: nil)
    assert_selector "#log_in"
    seed_legacy_caches
    # Observe the cache state at the native form submission boundary. The
    # passkey component intentionally calls form.submit(), not requestSubmit().
    page.execute_script(<<~JS)
      const submit = HTMLFormElement.prototype.submit
      HTMLFormElement.prototype.submit = async function() {
        const names = await caches.keys()
        sessionStorage.setItem("passkey-caches-at-submit", JSON.stringify(names))
        submit.call(this)
      }
    JS
    @authenticator = page.driver.browser.add_virtual_authenticator(options)
    credentials.each { |credential| @authenticator.add_credential(credential) }
    click_button "Sign in with a passkey"
    assert_selector "meta[name=current-user-id][content='#{users(:kevin).id}']", visible: :all
    names = JSON.parse(page.evaluate_script("sessionStorage.getItem('passkey-caches-at-submit')"))
    assert_empty names & %w[ main storage assets ]
    assert_no_legacy_caches
  end

  test "an updated worker removes legacy responses without reloading the page" do
    sign_in_as users(:david)
    wait_for_worker
    seed_legacy_caches

    assert page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      navigator.serviceWorker.register("/service-worker.js?upgrade=1", { scope: "/" }).then(registration => {
        const worker = registration.installing || registration.waiting
        if (!worker) { done(true); return }
        worker.addEventListener("statechange", () => {
          if (worker.state === "activated") done(true)
          else if (worker.state === "redundant") done(false)
        })
      })
    JS
    assert_no_legacy_caches
  end

  test "static requests do not persist credentials in Cache Storage" do
    sign_in_as users(:david)
    wait_for_worker
    asset_url = page.evaluate_script("document.querySelector('link[rel=stylesheet]').href")
    assert_equal false, page.evaluate_async_script(<<~JS, asset_url)
      const [url, done] = arguments
      ;(async () => {
        await Promise.all((await caches.keys()).map(name => caches.delete(name)))
        const secret = "Bearer fake-offline-credential"
        const response = await fetch(url, { cache: "no-store", headers: { Authorization: secret } })
        await response.text()
        for (const name of await caches.keys()) {
          for (const request of await (await caches.open(name)).keys()) {
            if (request.headers.get("Authorization") === secret) return done(true)
          }
        }
        done(false)
      })()
    JS
  end

  test "public asset cache keys do not retain request metadata" do
    sign_in_as users(:david)
    wait_for_worker
    asset_url = page.evaluate_script("document.querySelector('link[rel=stylesheet]').href")
    assert_equal false, page.evaluate_async_script(<<~JS, asset_url)
      const [url, done] = arguments
      ;(async () => {
        await Promise.all((await caches.keys()).map(name => caches.delete(name)))
        const secret = "fake-referrer-secret"
        const referrer = new URL("/session/transfers/" + secret, location.origin).href
        await (await fetch(url, { cache: "no-store", referrer, headers: { "X-Api-Key": secret } })).text()
        for (const name of await caches.keys()) {
          for (const request of await (await caches.open(name)).keys()) {
            if (request.headers.get("X-Api-Key") === secret) return done(true)
          }
        }
        done(false)
      })()
    JS
  end

  private
    def wait_for_worker
      assert page.evaluate_async_script(<<~JS)
        const done = arguments[0]
        navigator.serviceWorker.ready.then(() => {
          if (navigator.serviceWorker.controller) done(true)
          else navigator.serviceWorker.addEventListener("controllerchange", () => done(true), { once: true })
        })
      JS
    end

    def fetch_body(url)
      page.evaluate_async_script(<<~JS, url)
        const [url, done] = arguments
        fetch(url, { cache: "no-store" }).then(response => response.text()).then(done).catch(() => done("network unavailable"))
      JS
    end

    def set_offline(value)
      browser = page.driver.browser
      browser.execute_cdp("Network.enable")
      conditions = { offline: value, latency: 0, downloadThroughput: -1, uploadThroughput: -1 }
      browser.execute_cdp("Network.emulateNetworkConditions", **conditions)
      # Workers have their own network target; disconnecting only the page
      # still lets the old worker reach the server.
      browser.execute_cdp("Target.getTargets")["targetInfos"].select { |target| target["type"] == "service_worker" }.each do |target|
        @worker_sessions ||= {}
        session_id = @worker_sessions[target["targetId"]] ||= browser.execute_cdp("Target.attachToTarget", targetId: target["targetId"], flatten: false)["sessionId"]
        browser.execute_cdp("Target.sendMessageToTarget", sessionId: session_id, message: { id: 1, method: "Network.enable" }.to_json)
        browser.execute_cdp("Target.sendMessageToTarget", sessionId: session_id, message: { id: 2, method: "Network.emulateNetworkConditions", params: conditions }.to_json)
      end
    end

    def seed_legacy_caches
      page.evaluate_async_script(<<~JS)
        const done = arguments[0]
        Promise.all(["main", "storage", "assets", "fizzy-pages-v2-old-session-1", "fizzy-assets-v2"].map(async name => {
          const cache = await caches.open(name)
          await cache.put("/old-private-data", new Response("previous account"))
        })).then(() => done())
      JS
    end

    def assert_no_legacy_caches
      assert page.evaluate_async_script(<<~JS)
        const done = arguments[0]
        const deadline = Date.now() + 1000
        async function check() {
          const names = await caches.keys()
          if (!["main", "storage", "assets", "fizzy-pages-v2-old-session-1", "fizzy-assets-v2"].some(name => names.includes(name))) done(true)
          else if (Date.now() > deadline) done(false)
          else setTimeout(check, 50)
        }
        check()
      JS
    end
end
