import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"
import { currentPushSubscription } from "helpers/push_subscription"

export default class extends Controller {
  async clearCache(event) {
    if (this.cleared) return
    event.preventDefault()
    if (this.clearing) return
    this.clearing = true

    try {
      await this.#clearCaches()
      this.cleared = true
      this.element.requestSubmit(event.submitter)
    } finally {
      this.clearing = false
    }
  }

  async logout(event) {
    if (this.submitting) return

    event.preventDefault()
    await this.#clearCaches()
    try {
      const subscription = await currentPushSubscription()
      await subscription?.unsubscribe()
    } finally {
      // The server also removes this session's registrations if local cleanup fails.
      this.submitting = true
      if (event.submitter) {
        this.element.requestSubmit(event.submitter)
      } else {
        this.element.requestSubmit()
      }
    }
  }

  async #clearCaches() {
    Turbo.cache.clear()
    // Keep only the worker's current public asset cache, as main does.
    if ("caches" in window) {
      const names = await caches.keys()
      await Promise.all(names.filter(name => name !== "fizzy-assets-v3").map(name => caches.delete(name)))
    }
  }
}
