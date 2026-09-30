import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "input", "description" ]
  static values = { url: String, kind: String, localKey: String }

  #timer
  #observer
  #request
  #revision = 0
  #attempted = false

  connect() {
    if (this.kindValue === "comment") {
      // local-save restores the user's draft on the next frame.
      this.#observer = new IntersectionObserver(entries => {
        if (entries.some(entry => entry.isIntersecting) && !this.#attempted) {
          this.#attempted = true
          this.#suggest()
        }
      })
      this.#observer.observe(this.inputTarget)
    }
  }

  disconnect() {
    clearTimeout(this.#timer)
    this.#observer?.disconnect()
    this.#request?.abort()
  }

  change() {
    this.#revision++
    clearTimeout(this.#timer)
    this.#request?.abort()
    if (this.kindValue === "title" && this.#empty) {
      this.#timer = setTimeout(() => this.#suggest(), 1200)
    }
  }

  async #suggest() {
    if (!this.#empty || this.#savedComment) return

    const revision = this.#revision
    const description = this.hasDescriptionTarget ? this.descriptionTarget.value : null
    if (this.kindValue === "title" && !this.#hasContent(description)) return

    this.#request = new AbortController()
    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content
        },
        body: JSON.stringify({ kind: this.kindValue, description }),
        signal: this.#request.signal
      })
      if (!response.ok || response.status === 204) return

      const { suggestion } = await response.json()
      if (!this.element.isConnected || revision !== this.#revision || !this.#empty || this.#savedComment || !suggestion?.trim()) return
      if (this.hasDescriptionTarget && description !== this.descriptionTarget.value) return

      if (this.kindValue === "title") {
        this.inputTarget.value = suggestion
        this.inputTarget.dispatchEvent(new Event("input", { bubbles: true }))
      } else {
        // The provider returns text, never trusted HTML or executable attachments.
        const paragraph = document.createElement("p")
        paragraph.textContent = suggestion
        this.inputTarget.value = paragraph.outerHTML
        this.inputTarget.dispatchEvent(new CustomEvent("lexxy:change", { bubbles: true }))
      }
    } catch {
      // Suggestions are optional. Keep normal editing available on failure.
    }
  }

  get #empty() {
    return this.kindValue === "title" ? !this.inputTarget.value.trim() : !this.#hasContent(this.inputTarget.value)
  }

  get #savedComment() {
    return this.kindValue === "comment" && this.hasLocalKeyValue && localStorage.getItem(this.localKeyValue)
  }

  #hasContent(html) {
    const content = new DOMParser().parseFromString(html || "", "text/html")
    return !!(content.body.textContent.trim() || content.querySelector("action-text-attachment, img, video, audio, table, hr"))
  }
}
