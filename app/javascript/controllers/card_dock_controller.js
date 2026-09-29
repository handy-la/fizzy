import { Controller } from "@hotwired/stimulus"

// Handy: shows the card dock once the top of the card (its header) has scrolled
// off screen, so Done, the stage arrows, the way back to the board and the jump to the
// bottom stay at hand while reading on.
export default class extends Controller {
  connect() {
    this.observer = new IntersectionObserver(([ entry ]) => this.#update(entry))
    this.reobserve()
  }

  disconnect() {
    this.observer.disconnect()
  }

  // A morph can swap the card header the dock watches: follow the new one.
  reobserve() {
    const sentinel = this.element.closest(".card-perma")?.querySelector(".card__header")
    if (sentinel === this.sentinel) return

    this.observer.disconnect()
    this.sentinel = sentinel
    if (sentinel) this.observer.observe(sentinel)
  }

  scrollToBottom() {
    window.scrollTo({ top: document.documentElement.scrollHeight, behavior: "smooth" })
  }

  // A morph copies the server's class list; keep what the scroll decided.
  preserveVisibility(event) {
    if (event.target === this.element && event.detail.attributeName === "class") {
      event.preventDefault()
    }
  }

  #update(entry) {
    const scrolledPast = !entry.isIntersecting && entry.boundingClientRect.bottom < 0
    this.element.classList.toggle("card-dock--visible", scrolledPast)
  }
}
