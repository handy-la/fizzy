import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "card", "bar" ]

  connect() {
    this.observer = new IntersectionObserver(() => this.#updateVisibility())
    this.reobserve()
  }

  disconnect() {
    this.observer.disconnect()
  }

  // A refresh can replace the card while leaving this controller connected.
  reobserve() {
    this.observer.disconnect()
    this.observer.observe(this.cardTarget)
    this.#updateVisibility()
  }

  // Turbo morphs must not restore the server's hidden attribute while scrolled.
  preserveVisibility(event) {
    if (event.target === this.barTarget && event.detail.attributeName === "hidden") {
      event.preventDefault()
    }
  }

  #updateVisibility() {
    this.barTarget.hidden = this.cardTarget.getBoundingClientRect().bottom > 0
  }
}
