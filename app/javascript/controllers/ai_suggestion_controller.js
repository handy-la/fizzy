import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "input", "description" ]
  static values = { url: String, kind: String, localKey: String }

  #timer
  #request
  #revision = 0
  #typed = false
  #focusIntent = false
  #attempted = false

  disconnect() {
    clearTimeout(this.#timer)
    this.#request?.abort()
  }

  intent(event) {
    if (!event.isTrusted) return
    if (event.type === "beforeinput" && /^(insert|delete)/.test(event.inputType) && this.kindValue === "title" && this.descriptionTarget.contains(event.target)) {
      this.#typed = true
    } else if (event.type === "pointerdown" || event.key === "Tab") {
      this.#focusIntent = true
      setTimeout(() => { this.#focusIntent = false }, 0)
    }
  }

  focus(event) {
    const authorized = event.isTrusted && this.#focusIntent && event.target.closest("[contenteditable]")
    this.#focusIntent = false
    if (authorized && this.kindValue === "comment" && !this.#attempted && !this.#request) {
      this.#suggest()
    }
  }

  change() {
    this.#revision++
    clearTimeout(this.#timer)
    this.#request?.abort()
    if (this.kindValue === "title" && this.#typed && this.#empty) {
      this.#timer = setTimeout(() => this.#suggest(), 1200)
    }
    this.#typed = false
  }

  async #suggest() {
    if (!this.#empty || this.#savedComment) return

    const revision = this.#revision
    const description = this.hasDescriptionTarget ? this.descriptionTarget.value : null
    if (this.kindValue === "title" && this.#text(description).length < 20) return

    // Survive morphs, form reopening and Turbo restoration without another generation.
    const key = `ai-suggestion:${this.urlValue}:${this.kindValue}`
    if (this.kindValue === "comment" && Number(sessionStorage.getItem(key)) > Date.now()) return
    if (this.kindValue === "comment") {
      this.#attempted = true
      sessionStorage.setItem(key, Date.now() + 300000)
    }

    const request = new AbortController()
    this.#request = request
    try {
      let response = await fetch(this.urlValue, {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content
        },
        body: JSON.stringify({ kind: this.kindValue, description }),
        signal: request.signal
      })
      if (!response.ok || response.status === 204) return
      let result = await response.json()
      for (let attempt = 0; response.status === 202 && attempt < 60; attempt++) {
        await new Promise(resolve => setTimeout(resolve, 1000))
        if (request.signal.aborted || !this.element.isConnected) return
        const url = new URL(this.urlValue, window.location.href)
        url.searchParams.set("request_id", result.request_id)
        response = await fetch(url, { credentials: "same-origin", headers: { "Accept": "application/json" }, signal: request.signal })
        if (!response.ok) return
        result = await response.json()
      }
      const suggestion = response.status === 200 ? result.suggestion : null
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
    } finally {
      if (this.#request === request) this.#request = null
    }
  }

  get #empty() {
    return this.kindValue === "title" ? !this.inputTarget.value.trim() : !this.#hasContent(this.inputTarget.value)
  }

  get #savedComment() {
    return this.kindValue === "comment" && this.hasLocalKeyValue && localStorage.getItem(this.localKeyValue)
  }

  #text(html) {
    return new DOMParser().parseFromString(html || "", "text/html").body.textContent.trim()
  }

  #hasContent(html) {
    const content = new DOMParser().parseFromString(html || "", "text/html")
    return !!(content.body.textContent.trim() || content.querySelector("action-text-attachment, img, video, audio, table, hr"))
  }
}
