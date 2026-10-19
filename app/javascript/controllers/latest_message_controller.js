import { Controller } from "@hotwired/stimulus"
import { lastVisibleComment, scrollToComment } from "helpers/comment_helpers"

// Handy: a card opens on the start of its latest message, where the dock's jump to
// the last comment goes. A link to one message (#comment_…) keeps that message, and
// going back through the history keeps where the reader left the card.

// The action of the Turbo visit in progress, if any.
let visit = null
addEventListener("turbo:visit", ({ detail }) => visit = detail.action)
addEventListener("turbo:load", () => visit = null)

export default class extends Controller {
  connect() {
    if (visit === "restore") return

    if (visit) {
      // A visit scrolls to the top after it renders the page: show the message once it has.
      this.showOnLoad = () => this.#showLatestMessage()
      document.addEventListener("turbo:load", this.showOnLoad, { once: true })
    } else {
      this.#showLatestMessage()
    }
  }

  disconnect() {
    document.removeEventListener("turbo:load", this.showOnLoad)
  }

  #showLatestMessage() {
    const comment = lastVisibleComment()
    if (comment && !location.hash) scrollToComment(comment, "instant", { below: this.#titleBarHeight })
  }

  // The title bar shows once the card scrolls away, over the message's author line.
  // It is still hidden here: measure it shown, in the same task, so nothing paints.
  get #titleBarHeight() {
    const bar = document.querySelector(".card-title-bar")
    if (!bar) return 0

    const hidden = bar.hidden
    bar.hidden = false
    const height = bar.offsetHeight
    bar.hidden = hidden
    return height
  }
}
