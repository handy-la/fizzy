import { Controller } from "@hotwired/stimulus"
import { post } from "@rails/request.js"
import { verifyPushSubscription } from "helpers/push_subscription"

export default class extends Controller {
  static classes = [ "enabled" ]
  static targets = [ "subscribeButton", "explainer" ]
  static values = { subscriptionsUrl: String, verificationUrl: String }
  
  async connect() {
    if (!this.#allowed) return

    this.element.classList.remove(this.enabledClass)

    switch(Notification.permission) {
      case "default":
        this.#showButtonToSubscribe()
        break
      case "granted":
        const registration = await this.#getServiceWorkerRegistration()
        const subscription = await registration?.pushManager?.getSubscription()

        if (registration && subscription && await verifyPushSubscription(subscription, this.verificationUrlValue)) {
          this.element.classList.add(this.enabledClass)
        } else {
          this.#showButtonToSubscribe()
        }
        break
    }
  }

  async attemptToSubscribe() {
    if (this.#allowed) {
      const registration = await this.#getServiceWorkerRegistration() || await this.#registerServiceWorker()

      switch(Notification.permission) {
        case "denied":  { break }
        case "granted": { await this.#subscribe(registration); break }
        case "default": { await this.#requestPermissionAndSubscribe(registration) }
      }
    }
  }

  async isEnabled() {
    if (this.#allowed) {
      const registration = await this.#getServiceWorkerRegistration()
      const existingSubscription = await registration?.pushManager?.getSubscription()

      return Notification.permission == "granted" && registration && existingSubscription &&
        await verifyPushSubscription(existingSubscription, this.verificationUrlValue)
    }
  }

  get #allowed() {
    return navigator.serviceWorker && window.Notification
  }

  async #getServiceWorkerRegistration() {
    return navigator.serviceWorker.getRegistration("/service-worker.js", { scope: "/" })
  }

  async #registerServiceWorker() {
    await navigator.serviceWorker.register("/service-worker.js", { scope: "/" })
    return navigator.serviceWorker.ready
  }

  async #subscribe(registration) {
    const existing = await registration.pushManager.getSubscription()
    if (existing && await verifyPushSubscription(existing, this.verificationUrlValue)) {
      this.element.classList.add(this.enabledClass)
      this.subscribeButtonTarget.hidden = true
    } else {
      const subscription = await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: this.#vapidPublicKey })
      await this.#syncPushSubscription(subscription)
    }
  }

  async #syncPushSubscription(subscription) {
    try {
      const response = await post(this.subscriptionsUrlValue, { body: this.#extractJsonPayloadAsString(subscription), responseKind: "json" })
      if (response.statusCode === 201) {
        this.element.classList.add(this.enabledClass)
        this.subscribeButtonTarget.hidden = true
        return
      }
    } catch {
      // Registration failed; discard the browser endpoint instead of retaining it.
    }

    await subscription.unsubscribe()
    this.#showButtonToSubscribe()
  }

  #showButtonToSubscribe() {
    this.subscribeButtonTarget.hidden = false
    this.explainerTarget.hidden = true
  }

  async #requestPermissionAndSubscribe(registration) {
    const permission = await Notification.requestPermission()
    if (permission === "granted") await this.#subscribe(registration)
  }

  get #vapidPublicKey() {
    const encodedVapidPublicKey = document.querySelector('meta[name="vapid-public-key"]').content
    return this.#urlBase64ToUint8Array(encodedVapidPublicKey)
  }

  #extractJsonPayloadAsString(subscription) {
    const { endpoint, keys: { p256dh, auth } } = subscription.toJSON()
    let clientId = localStorage.getItem("fizzy-push-client-id")
    if (!clientId) {
      clientId = crypto.randomUUID()
      localStorage.setItem("fizzy-push-client-id", clientId)
    }
    return JSON.stringify({ push_subscription: { endpoint, p256dh_key: p256dh, auth_key: auth, client_id: clientId } })
  }

  // VAPID public key comes encoded as base64 but service worker registration needs it as a Uint8Array
  #urlBase64ToUint8Array(base64String) {
    const padding = "=".repeat((4 - base64String.length % 4) % 4)
    const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/")

    const rawData = window.atob(base64)
    const outputArray = new Uint8Array(rawData.length)

    for (let i = 0; i < rawData.length; ++i) {
      outputArray[i] = rawData.charCodeAt(i)
    }

    return outputArray
  }
}
