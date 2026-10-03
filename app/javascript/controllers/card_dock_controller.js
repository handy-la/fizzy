import { Controller } from "@hotwired/stimulus"

// Handy: shows the card dock once the top of the card (its header) has scrolled
// off screen, so Done, the stage arrows, the way back to the board and the jump to the
// last comment stay at hand while reading on.

// Room left above the last comment, so its author line is not flush with the top edge.
const LAST_COMMENT_MARGIN = 16

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

  // Lands on the start of the last comment, not the end of the page: a long comment
  // is read from its top. A card with no comment on show goes to the bottom.
  scrollToLastComment() {
    const comment = this.#lastVisibleComment
    const top = comment
      ? comment.getBoundingClientRect().top + window.scrollY - LAST_COMMENT_MARGIN
      : document.documentElement.scrollHeight

    window.scrollTo({ top, behavior: "smooth" })
  }

  // A morph copies the server's class list; keep what the scroll decided.
  preserveVisibility(event) {
    if (event.target === this.element && event.detail.attributeName === "class") {
      event.preventDefault()
    }
  }

  // Older system comments stay hidden until the history is expanded: skip them.
  get #lastVisibleComment() {
    const comments = document.querySelectorAll(".comments .comment:not(.comment--new)")
    return Array.from(comments).findLast(comment => comment.getClientRects().length > 0)
  }

  #update(entry) {
    const scrolledPast = !entry.isIntersecting && entry.boundingClientRect.bottom < 0
    this.element.classList.toggle("card-dock--visible", scrolledPast)
  }
}
