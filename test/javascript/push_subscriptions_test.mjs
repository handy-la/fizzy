import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import { resolve, dirname } from "node:path"
import test from "node:test"
import vm from "node:vm"

async function browser({ response, failure, verificationUrl = "/1/users/david/push_subscription_verification" } = {}) {
  const calls = []
  const classes = new Set()
  const subscription = {
    toJSON: () => ({ endpoint: "https://fcm.googleapis.com/fcm/send/browser", keys: { p256dh: "key", auth: "auth" } }),
    unsubscribe: async () => { calls.push("unsubscribe"); return true }
  }
  const registration = { pushManager: { getSubscription: async () => subscription } }
  const context = vm.createContext({
    navigator: { serviceWorker: { getRegistration: async () => registration } },
    window: { Notification: {} },
    Notification: { permission: "granted" },
    document: { querySelector: () => verificationUrl ? ({ content: verificationUrl }) : null },
    console
  })
  const cache = new Map()
  async function load(path) {
    if (!cache.has(path)) {
      const module = new vm.SourceTextModule(await readFile(path, "utf8"), { context, identifier: path })
      cache.set(path, module)
      await module.link(async (specifier, importer) => {
        if (specifier === "@hotwired/stimulus") {
          return new vm.SyntheticModule([ "Controller" ], function() { this.setExport("Controller", class {}) }, { context })
        }
        if (specifier === "@hotwired/turbo-rails") {
          return new vm.SyntheticModule([ "Turbo" ], function() {
            this.setExport("Turbo", { offline: { clearCache: async () => calls.push("clearCache") } })
          }, { context })
        }
        if (specifier === "@rails/request.js") {
          return new vm.SyntheticModule([ "post" ], function() {
            this.setExport("post", async (url, options) => {
              calls.push({ url, body: JSON.parse(options.body) })
              if (failure) throw failure
              return await response
            })
          }, { context })
        }
        const target = specifier.startsWith("helpers/") ? resolve("app/javascript", `${specifier}.js`) : resolve(dirname(importer.identifier), specifier)
        return load(target)
      })
    }
    return cache.get(path)
  }
  const module = await load(resolve("app/javascript/controllers/notifications_controller.js"))
  await module.evaluate()
  const controller = new module.namespace.default()
  Object.assign(controller, {
    element: { classList: { add: value => classes.add(value), remove: value => classes.delete(value) } },
    enabledClass: "on",
    subscriptionsUrlValue: "/1/users/david/push_subscriptions",
    verificationUrlValue: "/1/users/david/push_subscription_verification",
    subscribeButtonTarget: { hidden: true },
    explainerTarget: { hidden: false }
  })
  const logoutView = await readFile("app/views/my/menus/_settings.html.erb", "utf8")
  const logoutAction = logoutView.match(/submit->clear-offline-cache#(\w+)/)[1]
  return { controller, calls, classes, load, subscription, logoutAction }
}

test("existing subscription waits for server reconciliation before enabling UI", async () => {
  let respond
  const response = new Promise(resolve => { respond = resolve })
  const { controller, calls, classes } = await browser({ response })
  const connecting = controller.connect()
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(classes.has("on"), false)
  assert.equal(calls.length, 1, "connect must verify the subscription on the server")
  respond({ ok: true, statusCode: 204 })
  await connecting
  assert.equal(classes.has("on"), true)
})

test("a subscription belonging to another user is unsubscribed and needs consent", async () => {
  const { controller, calls, classes } = await browser({ response: { ok: false, statusCode: 409 } })
  await controller.connect()
  assert.equal(classes.has("on"), false)
  assert.equal(controller.subscribeButtonTarget.hidden, false)
  assert.ok(calls.includes("unsubscribe"))
})

test("an unverified HTTP 200 cannot enable notifications or revoke the endpoint", async () => {
  const { controller, calls, classes } = await browser({ response: { ok: true, statusCode: 200 } })
  await controller.connect()
  assert.equal(classes.has("on"), false)
  assert.equal(calls.includes("unsubscribe"), false)
})

test("network failure retains the subscription without assuming its owner", async () => {
  const { controller, calls, classes } = await browser({ failure: new Error("offline") })
  await controller.connect()
  assert.equal(classes.has("on"), false)
  assert.equal(calls.includes("unsubscribe"), false)
})


test("a transient server error retains the subscription without enabling notifications", async () => {
  const { controller, calls, classes } = await browser({ response: { ok: false, statusCode: 503 } })
  await controller.connect()
  assert.equal(classes.has("on"), false)
  assert.equal(calls.includes("unsubscribe"), false)
})

test("startup without an authenticated user unsubscribes without assuming ownership", async () => {
  const { load, calls } = await browser({ verificationUrl: null })
  const helper = await load(resolve("app/javascript/helpers/push_subscription.js"))
  await helper.namespace.reconcilePushSubscription()
  assert.deepEqual(calls, [ "unsubscribe" ])
})

test("logout waits for unsubscribe before submitting the form", async () => {
  const { load, calls, subscription, logoutAction } = await browser()
  let unsubscribe
  subscription.unsubscribe = () => new Promise(resolve => { unsubscribe = resolve })
  const module = await load(resolve("app/javascript/controllers/clear_offline_cache_controller.js"))
  await module.evaluate()
  const controller = new module.namespace.default()
  controller.element = { requestSubmit: () => calls.push("submit") }
  const event = { preventDefault: () => calls.push("preventDefault"), submitter: null }
  const logout = controller[logoutAction](event)
  await new Promise(resolve => setImmediate(resolve))
  assert.deepEqual(calls, [ "preventDefault", "clearCache" ])
  unsubscribe(true)
  await logout
  assert.equal(calls.at(-1), "submit")
  await controller[logoutAction](event)
  assert.equal(calls.filter(call => call === "submit").length, 1)
})

test("logout still submits when the browser cannot unsubscribe", async () => {
  const { load, calls, subscription, logoutAction } = await browser()
  subscription.unsubscribe = async () => { throw new Error("push manager unavailable") }
  const module = await load(resolve("app/javascript/controllers/clear_offline_cache_controller.js"))
  await module.evaluate()
  const controller = new module.namespace.default()
  controller.element = { requestSubmit: () => calls.push("submit") }
  await assert.rejects(controller[logoutAction]({ preventDefault() {}, submitter: null }))
  assert.equal(calls.at(-1), "submit")
})

async function pushEvent({ status = 204, failure, verificationUrl = "/1/users/david/push_subscription_verification?token=signed" } = {}) {
  const shown = [], badges = [], requests = [], listeners = {}
  const source = await readFile("app/views/pwa/service_worker.js.erb", "utf8")
  const context = vm.createContext({
    importScripts() {},
    TurboOffline: { addRule() {}, start() {}, handlers: { networkFirst() {}, cacheFirst() {} } },
    self: {
      addEventListener: (name, listener) => { listeners[name] = listener },
      registration: { showNotification: async (...args) => shown.push(args) },
      navigator: { setAppBadge: async badge => badges.push(badge) }
    },
    fetch: async (url, options) => {
      requests.push({ url, options })
      if (failure) throw failure
      return { status }
    }
  })
  vm.runInContext(source.replace(/<%[\s\S]*?%>/g, ""), context)
  let processing
  listeners.push({
    data: { json: () => ({ title: "Private title", options: { body: "Private extract", data: { badge: 3, verification_url: verificationUrl } } }) },
    waitUntil: promise => { processing = promise }
  })
  await processing
  return { shown, badges, requests }
}

test("service worker verifies the original registration before displaying a push", async () => {
  const { shown, badges, requests } = await pushEvent()
  assert.equal(shown.length, 1)
  assert.deepEqual(badges, [ 3 ])
  assert.equal(requests.length, 1)
  assert.equal(requests[0].options.cache, "no-store")
  assert.equal(requests[0].options.redirect, "error")
})

for (const status of [ 200, 403 ]) {
  test(`service worker suppresses queued push when verification returns ${status}`, async () => {
    const { shown, badges } = await pushEvent({ status })
    assert.deepEqual(shown, [])
    assert.deepEqual(badges, [])
  })
}

test("service worker suppresses push when offline or carrying an old payload", async () => {
  for (const options of [ { failure: new Error("offline") }, { verificationUrl: null } ]) {
    const { shown, badges } = await pushEvent(options)
    assert.deepEqual(shown, [])
    assert.deepEqual(badges, [])
  }
})
