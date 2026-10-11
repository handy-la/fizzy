import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

export default class extends Controller {
  async clearCache(event) {
    if (this.cleared) return
    event.preventDefault()
    Turbo.cache.clear()

    // The worker also clears before session transitions. Wait here for browsers
    // whose page is not controlled yet, and submit only after deletion succeeds.
    if ("caches" in window) {
      const names = await caches.keys()
      await Promise.all(names.filter(name => name !== "fizzy-assets-v2").map(name => caches.delete(name)))
    }
    this.cleared = true
    this.element.requestSubmit(event.submitter)
  }
}
