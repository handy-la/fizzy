require "application_system_test_case"

class OfflineCacheTest < ApplicationSystemTestCase
  include WebauthnTestHelper
  setup do
    sign_in_as users(:kevin)
    ready = Capybara.using_wait_time(15) { page.evaluate_async_script(<<~JS) }
      const done = arguments[0]
      navigator.serviceWorker.register("/service-worker.js", { scope: "/" }).then(async registration => {
        const worker = registration.installing || registration.waiting || registration.active
        if (worker.state !== "activated") {
          await new Promise(resolve => worker.addEventListener("statechange", () => {
            if (worker.state === "activated") resolve()
          }))
        }
        if (!navigator.serviceWorker.controller) {
          await new Promise(resolve => navigator.serviceWorker.addEventListener("controllerchange", resolve, { once: true }))
        }
        done(true)
      }).catch(error => done({ error: error.message }))
    JS
    assert_equal true, ready
  end

  teardown do
    set_offline(false) if @offline
    @worker_connection&.close
    @worker_connection = nil
  end

  test "activation clears legacy capabilities even with an open IndexedDB connection" do
    result = Capybara.using_wait_time(15) { page.evaluate_async_script(<<~JS) }
      const done = arguments[0]
      ;(async () => {
        const secretURL = new URL("/session/transfers/fake-offline-secret", location.origin).href
        await (await caches.open("main")).put(secretURL, new Response("fake-offline-secret"))
        const registry = await new Promise((resolve, reject) => {
          const opening = indexedDB.open("turbo-offline-database", 1)
          opening.onupgradeneeded = () => {
            opening.result.createObjectStore("cache-registry", { keyPath: "key" })
              .createIndex("cacheNameAndTimestamp", ["cacheName", "timestamp"])
          }
          opening.onsuccess = () => resolve(opening.result)
          opening.onerror = () => reject(opening.error)
        })
        window.legacyRegistry = registry
        await new Promise(resolve => {
          const transaction = registry.transaction("cache-registry", "readwrite")
          transaction.objectStore("cache-registry").put({ key: secretURL, cacheName: "main", timestamp: Date.now() })
          transaction.oncomplete = resolve
        })
        // A fresh scope runs the real activation handler even when the script
        // bytes have not changed. Keep the legacy database connection open.
        const registration = await navigator.serviceWorker.register("/service-worker.js", { scope: "/migration-test/" })
        const worker = registration.installing || registration.waiting || registration.active
        if (worker.state !== "activated") {
          await new Promise(resolve => worker.addEventListener("statechange", () => {
            if (worker.state === "activated") resolve()
          }))
        }
        const count = await new Promise(resolve => {
          const query = registry.transaction("cache-registry").objectStore("cache-registry").count()
          query.onsuccess = () => resolve(query.result)
        })
        const cached = await caches.match(secretURL)
        registry.close()
        await registration.unregister()
        done({ cached: !!cached, count })
      })().catch(error => done({ error: error.message }))
    JS
    assert_equal({ "cached" => false, "count" => 0 }, result)
  ensure
    page.execute_script("window.legacyRegistry?.close()")
  end

  test "PAT reveal and transfer page never enter Cache Storage" do
    identity = users(:kevin).identity
    identity.regenerate_transfer_token
    token = identity.transfer.token

    result = page.evaluate_async_script(<<~JS, my_access_tokens_path, user_path(users(:kevin)), token)
      const [tokensPath, userPath, transferToken, done] = arguments
      ;(async () => {
        const created = await fetch(tokensPath, {
          method: "POST",
          headers: { "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "",
                     "Content-Type": "application/x-www-form-urlencoded" },
          body: "access_token[description]=Offline+test&access_token[permission]=read"
        })
        const reveal = await (await fetch(created.url)).text()
        const transfer = await (await fetch(userPath)).text()
        // The old worker writes after resolving fetch. Wait for its writes to settle.
        await new Promise(resolve => setTimeout(resolve, 500))
        const entries = []
        for (const name of await caches.keys()) {
          const cache = await caches.open(name)
          for (const request of await cache.keys()) {
            entries.push({ url: request.url, body: await (await cache.match(request)).text() })
          }
        }
        done({ revealed: reveal.includes("Be sure to save this access token now"), transferShown: transfer.includes(transferToken),
               revealCached: entries.some(entry => entry.url.includes("access_tokens")),
               transferCached: entries.some(entry => entry.body.includes(transferToken)) })
      })().catch(error => done({ error: error.message }))
    JS

    assert_equal true, result["revealed"], result.inspect
    assert_equal true, result["transferShown"], result.inspect
    assert_equal false, result["revealCached"], result.inspect
    assert_equal false, result["transferCached"], result.inspect
  end

  test "a revoked session cannot recover a private board offline" do
    path = board_path(boards(:writebook))
    visit path
    assert_text boards(:writebook).name
    identities(:kevin).sessions.destroy_all
    set_offline(true)
    assert_equal false, page.evaluate_async_script(<<~JS, path)
      const [path, done] = arguments
      fetch(path).then(response => done(response.ok)).catch(() => done(false))
    JS
  end

  test "exports notifications JSON and private blobs are never cached" do
    card = cards(:logo)
    Current.with(session: sessions(:kevin)) do
      card.image.attach io: file_fixture("moon.jpg").open, filename: "private.jpg", content_type: "image/jpeg"
    end
    export = users(:kevin).data_exports.create!(account: accounts("37s"))
    export.build
    paths = [ user_data_export_path(users(:kevin), export), notifications_path,
              board_path(boards(:writebook), format: :json), rails_blob_path(card.image.blob, disposition: :inline) ]
    result = page.evaluate_async_script(<<~JS, paths)
      const [paths, done] = arguments
      ;(async () => {
        const statuses = []
        for (const path of paths) {
          const response = await fetch(path, { headers: { Accept: path.endsWith(".json") ? "application/json" : "text/html" } })
          await response.arrayBuffer()
          statuses.push(response.status)
        }
        await new Promise(resolve => setTimeout(resolve, 500))
        const cached = []
        for (const name of await caches.keys()) {
          for (const request of await (await caches.open(name)).keys()) {
            if (paths.includes(new URL(request.url).pathname) || request.url.includes("/rails/active_storage/")) cached.push(request.url)
          }
        }
        done({ statuses, cached })
      })().catch(error => done({ error: error.message }))
    JS
    assert_equal [ 200 ] * paths.size, result["statuses"], result.inspect
    assert_empty result["cached"], result.inspect
  end

  test "JSON logout awaits private cache deletion and sensitive URLs fail offline" do
    board_path = board_path(boards(:writebook))
    result = page.evaluate_async_script(<<~JS, board_path, session_path(script_name: nil, format: :json))
      const [boardPath, logoutPath, done] = arguments
      ;(async () => {
        await fetch(boardPath, { headers: { Accept: "text/html" } })
        await new Promise(resolve => setTimeout(resolve, 500))
        const before = []
        for (const name of await caches.keys()) {
          const cache = await caches.open(name)
          if ((await cache.keys()).some(request => new URL(request.url).pathname === boardPath)) before.push(name)
        }
        const response = await fetch(logoutPath, {
          method: "DELETE",
          headers: { "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" }
        })
        const remaining = []
        for (const name of await caches.keys()) {
          const cache = await caches.open(name)
          remaining.push(...(await cache.keys()).filter(request => new URL(request.url).pathname === boardPath))
        }
        done({ cached: before.length > 0, status: response.status, remaining: remaining.length })
      })().catch(error => done({ error: error.message }))
    JS
    assert_equal false, result["cached"], result.inspect
    assert_equal 204, result["status"], result.inspect
    assert_equal 0, result["remaining"], result.inspect

    set_offline(true)
    paths = [ board_path, my_access_tokens_path, user_path(users(:kevin)), "/session/transfers/invalid" ]
    assert_equal [ false ] * paths.size, page.evaluate_async_script(<<~JS, paths)
      const [paths, done] = arguments
      Promise.all(paths.map(path => fetch(path).then(response => ({ status: response.status, url: response.url })).catch(() => false))).then(done)
    JS
  end

  test "private HTML and JSON stay out of Cache Storage across accounts" do
    other_account = accounts(:initech)
    user = User.create!(identity: users(:kevin).identity, account: other_account, name: "Kevin Elsewhere", role: "admin")
    board = Current.set(account: other_account, user: user) { Board.create!(name: "Other account", creator: user) }
    paths = [ board_path(boards(:writebook)), board_path(board, script_name: "/#{other_account.external_account_id}") ]

    stored = page.evaluate_async_script(<<~JS, paths)
      const [paths, done] = arguments
      ;(async () => {
        const headers = []
        for (const path of paths) {
          const response = await fetch(path, { headers: { Accept: "text/html" } })
          headers.push({ scope: response.headers.get("X-Fizzy-Offline-Session"), account: response.headers.get("X-Fizzy-Offline-Account"), policy: response.headers.get("Cache-Control") })
        }
        await fetch(paths[0], { headers: { Accept: "application/json" } })
        await new Promise(resolve => setTimeout(resolve, 500))
        const partitions = []
        for (const path of paths) {
          const matches = []
          for (const name of await caches.keys()) {
            const cache = await caches.open(name)
            if (await cache.match(path, { ignoreVary: true })) matches.push(name)
          }
          partitions.push(matches)
        }
        done({ partitions, headers })
      })().catch(error => done({ error: error.message }))
    JS
    assert_equal [ 0, 0 ], stored["partitions"].map(&:size), stored.inspect

    set_offline(true)
    assert_equal [ false, false, false, false ], page.evaluate_async_script(<<~JS, paths)
      const [paths, done] = arguments
      const html = path => fetch(path, { headers: { Accept: "text/html" } }).then(response => response.ok).catch(() => false)
      const json = fetch(paths[0], { headers: { Accept: "application/json" } }).then(() => true).catch(() => false)
      Promise.all([html(paths[0]), html(paths[1]), html("/9999/boards"), json]).then(done)
    JS
  end

  test "no-store responses remove a legacy private page" do
    path = board_path(boards(:writebook))
    page.evaluate_async_script(<<~JS, path)
      const [path, done] = arguments
      ;(async () => {
        await fetch(path, { headers: { Accept: "text/html" } })
        await (await caches.open("fizzy-pages-v2-retired-session")).put(path, new Response("previous account"))
        done(true)
      })()
    JS
    worker_command("Runtime.evaluate", expression: <<~JS)
      globalThis.originalFetch = fetch
      globalThis.fetch = async (...args) => {
        const response = await originalFetch(...args)
        const headers = new Headers(response.headers)
        headers.set("Cache-Control", "private, No-Store")
        return new Response(await response.arrayBuffer(), { status: response.status, headers })
      }
    JS
    assert_equal false, page.evaluate_async_script(<<~JS, path)
      const [path, done] = arguments
      ;(async () => {
        await fetch(path, { headers: { Accept: "text/html" } })
        for (const name of await caches.keys()) {
          if (await (await caches.open(name)).match(path, { ignoreVary: true })) return done(true)
        }
        done(false)
      })()
    JS
  ensure
    worker_command("Runtime.evaluate", expression: "globalThis.fetch = originalFetch") if @worker_connection
  end

  test "a response started before JSON logout cannot repopulate private storage" do
    path = board_path(boards(:writebook))
    worker_command("Runtime.evaluate", expression: <<~JS)
      globalThis.originalFetch = fetch
      globalThis.networkReady = new Promise(resolve => globalThis.markReady = resolve)
      globalThis.networkHeld = new Promise(resolve => globalThis.releaseNetwork = resolve)
      globalThis.fetch = async (...args) => {
        const response = await originalFetch(...args)
        if (new URL(args[0].url).pathname === #{path.to_json}) {
          markReady()
          await networkHeld
        }
        return response
      }
    JS
    page.execute_script("window.pendingBoard = fetch(arguments[0], { headers: { Accept: 'text/html' } })", path)
    worker_command("Runtime.evaluate", expression: "networkReady", awaitPromise: true)
    page.evaluate_async_script(<<~JS, session_path(script_name: nil, format: :json))
      const [path, done] = arguments
      fetch(path, { method: "DELETE" }).then(response => done(response.status))
    JS
    worker_command("Runtime.evaluate", expression: "releaseNetwork()")
    assert_equal false, page.evaluate_async_script(<<~JS, path)
      const [path, done] = arguments
      ;(async () => {
        await window.pendingBoard
        await new Promise(resolve => setTimeout(resolve, 500))
        for (const name of await caches.keys()) {
          if (await (await caches.open(name)).match(path, { ignoreVary: true })) return done(true)
        }
        done(false)
      })()
    JS
  ensure
    worker_command("Runtime.evaluate", expression: "releaseNetwork(); globalThis.fetch = originalFetch") if @worker_connection
  end

  test "HTML logout deletes previously visited pages" do
    cache_board
    visit user_path(users(:kevin))
    click_button "Sign out of Fizzy on this device"
    assert_current_path new_session_path(script_name: nil)
    assert_no_cached_board
  end

  test "a native transfer form deletes the previous identity's pages" do
    cache_board
    identities(:kevin).sessions.destroy_all
    submit_native_form(session_transfer_path(identities(:david).transfer_id, script_name: nil), { "_method" => "put" })
    assert_current_path root_path
    assert_selector "meta[name='current-user-id'][content='#{users(:david).id}']", visible: false
    assert_no_cached_board
  end

  test "a native passkey form deletes the previous identity's pages" do
    cache_board
    credential = identities(:david).passkeys.create!(name: "Offline Test", credential_id: Base64.urlsafe_encode64(SecureRandom.random_bytes(32), padding: false), public_key: webauthn_private_key.public_to_der, sign_count: 0)
    assertion = build_assertion_params(challenge: webauthn_challenge(purpose: "authentication"), credential: credential)
    fields = assertion[:passkey].transform_keys { |key| "passkey[#{key}]" }
    identities(:kevin).sessions.destroy_all
    submit_native_form(session_passkey_path(script_name: nil), fields)
    assert_current_path root_path
    assert_selector "meta[name='current-user-id'][content='#{users(:david).id}']", visible: false
    assert_no_cached_board
  end

  private
    def cache_board
      assert_equal false, page.evaluate_async_script(<<~JS, board_path(boards(:writebook)))
        const [path, done] = arguments
        ;(async () => {
          await fetch(path, { headers: { Accept: "text/html" } })
          for (const name of await caches.keys()) {
            if (await (await caches.open(name)).match(path, { ignoreVary: true })) return done(true)
          }
          done(false)
        })()
      JS
    end

    def assert_no_cached_board
      assert_equal false, page.evaluate_async_script(<<~JS, board_path(boards(:writebook)))
        const [path, done] = arguments
        ;(async () => {
          for (const name of await caches.keys()) {
            if (await (await caches.open(name)).match(path, { ignoreVary: true })) return done(true)
          }
          done(false)
        })()
      JS
    end

    def submit_native_form(path, fields)
      page.execute_script(<<~JS, path, fields)
        const [path, fields] = arguments
        const form = document.createElement("form")
        form.action = path
        form.method = "post"
        for (const [name, value] of Object.entries(fields)) {
          const input = document.createElement("input")
          input.name = name
          input.value = value
          form.append(input)
        }
        document.body.append(form)
        form.submit()
      JS
    end

    def webauthn_client_data_json(challenge:, type:)
      uri = URI(page.current_url)
      { challenge: challenge, origin: "#{uri.scheme}://#{uri.host}:#{uri.port}", type: type }.to_json
    end

    def build_assertion_auth_data(sign_count:)
      [ Digest::SHA256.digest(URI(page.current_url).host), [ 0x05 ].pack("C"), [ sign_count ].pack("N") ].join.b
    end

    def set_offline(offline)
      @offline = offline
      # Chrome scopes network emulation to each target. Making only the page
      # offline still lets its service worker fetch from the server.
      conditions = { urlPattern: "", offline: offline, latency: 0, downloadThroughput: -1, uploadThroughput: -1 }
      page.driver.browser.execute_cdp("Network.enable")
      page.driver.browser.execute_cdp("Network.emulateNetworkConditionsByRule", offline: offline, emulateOfflineServiceWorker: offline, matchedNetworkConditions: [ conditions ])
      worker_command("Network.enable")
      worker_command("Network.emulateNetworkConditionsByRule", offline: offline, emulateOfflineServiceWorker: offline, matchedNetworkConditions: [ conditions ])
    end

    def worker_command(method, **params)
      unless @worker_connection
        driver = page.driver.browser
        targets = driver.execute_cdp("Target.getTargets")["targetInfos"]
        worker = targets.find { |target| target["type"] == "service_worker" && target["url"] == "#{URI(page.current_url).scheme}://#{URI(page.current_url).host}:#{URI(page.current_url).port}/service-worker.js" }
        assert worker, "The browser has no service worker target"
        @worker_connection = Selenium::WebDriver::WebSocketConnection.new(url: driver.send(:devtools_url))
        attached = @worker_connection.send_cmd(method: "Target.attachToTarget", params: { targetId: worker["targetId"], flatten: true })
        @worker_session = attached.dig("result", "sessionId")
      end
      result = @worker_connection.send_cmd(method: method, params: params, sessionId: @worker_session)
      assert_nil result["error"], result.inspect
      result["result"]
    end
end
