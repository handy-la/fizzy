import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"

export default class extends Controller {
  static targets = [ "input", "description", "status", "retry" ]
  static values = { url: String, kind: String, localKey: String, user: String }

  #timer
  #deadline
  #request
  #subscription
  #observer
  #revision = 0
  #typed = false
  #focusIntent = false
  #tapFocus = false
  #active
  #proposal
  #input
  #titlePlaceholder
  #preparing = false
  #composing = false
  #keydown = event => this.#accept(event)
  #compositionStart = () => { this.#composing = true }
  #compositionEnd = () => { this.#composing = false }
  #refresh = () => { this.#subscription?.perform("recover") }

  connect() {
    this.#input = this.inputTarget
    document.addEventListener("turbo:before-stream-render", this.#refresh)
    if (this.kindValue === "title") {
      this.#titlePlaceholder = this.#input.getAttribute("placeholder") || ""
      this.#observer = new MutationObserver(() => this.#renderPlaceholder())
      this.#observer.observe(this.#input, { attributes: true, attributeFilter: [ "placeholder" ] })
    } else if (this.kindValue === "comment") {
      this.inputTarget.dataset.aiSuggestionPlaceholder ??= this.inputTarget.getAttribute("placeholder") || ""
      // Capture on the ancestor, before Lexical's listener on its editable root.
      this.element.addEventListener("keydown", this.#keydown, true)
      this.element.addEventListener("compositionstart", this.#compositionStart, true)
      this.element.addEventListener("compositionend", this.#compositionEnd, true)
      this.#observer = new MutationObserver(() => this.#renderPlaceholder())
      this.#observer.observe(this.inputTarget, { childList: true, subtree: true, attributes: true, attributeFilter: [ "placeholder" ] })
      const saved = this.#stored
      if (saved?.failed && this.#empty && !this.#savedComment) {
        this.#showStatus("No se pudo obtener la sugerencia.", true)
      } else if (saved && !saved.dismissed && this.#empty && !this.#savedComment) {
        this.#active = { token: saved.token, revision: this.#revision }
        this.#subscribe(this.#active)
      }
    }
  }

  disconnect() {
    clearTimeout(this.#timer)
    clearTimeout(this.#deadline)
    this.#request?.abort()
    this.#request = null
    this.#subscription?.unsubscribe()
    this.#subscription = null
    this.#active = null
    this.#observer?.disconnect()
    this.element.removeEventListener("keydown", this.#keydown, true)
    this.element.removeEventListener("compositionstart", this.#compositionStart, true)
    this.element.removeEventListener("compositionend", this.#compositionEnd, true)
    document.removeEventListener("turbo:before-stream-render", this.#refresh)
    this.#proposal = null
    this.#renderPlaceholder()
    this.#showStatus("")
  }

  intent(event) {
    if (!event.isTrusted) return
    if (event.type === "beforeinput" && /^(insert|delete)/.test(event.inputType) && this.kindValue === "title" && this.descriptionTarget.contains(event.target)) {
      this.#typed = true
    } else if (event.type === "pointerdown" || event.key === "Tab") {
      this.#focusIntent = true
      setTimeout(() => { this.#focusIntent = false }, 0)
    } else if (event.type === "click") {
      // A touch tap focuses only after the finger lifts, when the pointerdown
      // intent has expired. Its click, inside the focused editor, authorizes.
      const authorized = this.#tapFocus && event.target.closest("[contenteditable]")?.contains(document.activeElement)
      this.#tapFocus = false
      if (authorized) this.#suggestComment()
    }
  }

  focus(event) {
    const editable = event.isTrusted && event.target.closest("[contenteditable]")
    const authorized = editable && this.#focusIntent
    this.#tapFocus = !!editable && !this.#focusIntent
    this.#focusIntent = false
    if (authorized) this.#suggestComment()
  }

  change() {
    this.#revision++
    clearTimeout(this.#timer)
    this.#request?.abort()
    this.#dismiss()
    if (this.kindValue === "title" && this.#typed && this.#empty) {
      this.#timer = setTimeout(() => this.#suggest(), 1200)
    }
    this.#typed = false
  }

  retry() {
    if (this.#empty && !this.#savedComment && !this.#request) {
      sessionStorage.removeItem(this.#key)
      this.#active = null
      this.#suggest()
    }
  }

  #suggestComment() {
    if (this.kindValue === "comment" && !this.#stored && !this.#request && !this.#active) this.#suggest()
  }

  async #suggest() {
    if (!this.#empty || this.#savedComment) return
    const revision = this.#revision
    const description = this.hasDescriptionTarget ? this.descriptionTarget.value : null
    if (this.kindValue === "title" && this.#text(description).length < 20) return
    const request = new AbortController()
    this.#request = request
    this.#showStatus("Preparando sugerencia…")
    try {
      const response = await fetch(this.urlValue, {
        method: "POST", credentials: "same-origin",
        headers: {
          "Content-Type": "application/json", "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content
        },
        body: JSON.stringify({ kind: this.kindValue, description }), signal: request.signal
      })
      if (response.status === 204) { this.#showStatus(""); return }
      if (!response.ok) throw new Error("Suggestion unavailable")
      const result = await response.json()
      if (revision !== this.#revision || !this.element.isConnected) return
      this.#active = { token: result.request_id, revision, description }
      if (this.kindValue === "comment") this.#store({ token: result.request_id, expires: Date.parse(result.expires_at), dismissed: false })
      this.#receive({ ...result, revision }, this.#active)
      if (this.#active && result.request_id) await this.#subscribe(this.#active)
    } catch (error) {
      if (error.name !== "AbortError") this.#showStatus("No se pudo obtener la sugerencia.", true)
    } finally {
      if (this.#request === request) this.#request = null
    }
  }

  async #subscribe(active) {
    if (this.#active !== active || !this.element.isConnected) return
    this.#subscription?.unsubscribe()
    const controller = this
    const subscription = await cable.subscribeTo({ channel: "CardSuggestionChannel", token: active.token, revision: active.revision }, {
      connected() { this.perform("recover") },
      received(data) { controller.#receive(data, active) },
      rejected() { controller.#recover(active) }
    })
    if (this.#active !== active || !this.element.isConnected) subscription.unsubscribe()
    else this.#subscription = subscription
  }

  #receive(result, active) {
    if (this.#active !== active || result.request_id !== active.token || result.revision !== active.revision || active.revision !== this.#revision) return
    if (!this.element.isConnected || !this.#empty || this.#savedComment) { this.#dismiss(); return }
    if (this.hasDescriptionTarget && active.description !== this.descriptionTarget.value) { this.#dismiss(); return }
    clearTimeout(this.#deadline)
    const expires = Date.parse(result.expires_at)
    if (this.kindValue === "comment" && Number.isFinite(expires)) this.#store({ token: active.token, expires, dismissed: false })
    if (result.status === "pending" || result.status === "running") {
      this.#showStatus("Preparando sugerencia…")
      // One recovery at the server deadline, never a periodic polling loop.
      this.#deadline = setTimeout(() => this.#recover(active), Math.max(0, expires - Date.now()) + 1000)
    } else if (result.status === "completed" && result.suggestion?.trim() && expires > Date.now()) {
      this.#showStatus("")
      if (this.kindValue === "title") {
        this.inputTarget.value = result.suggestion
        this.inputTarget.dispatchEvent(new Event("input", { bubbles: true }))
        this.#dismiss()
      } else {
        this.#proposal = { text: result.suggestion, expires }
        this.#renderPlaceholder()
        this.#deadline = setTimeout(() => this.#dismiss(), expires - Date.now())
      }
    } else {
      this.#dismiss()
      this.#rememberFailure()
      this.#showStatus("No se pudo obtener la sugerencia.", true)
    }
  }

  async #recover(active) {
    if (this.#active !== active || !this.element.isConnected) return
    try {
      const url = new URL(this.urlValue, window.location.href)
      url.searchParams.set("request_id", active.token)
      const response = await fetch(url, { credentials: "same-origin", headers: { "Accept": "application/json" } })
      if (!response.ok) throw new Error("Suggestion unavailable")
      this.#receive({ ...await response.json(), revision: active.revision }, active)
    } catch {
      if (this.#active === active) {
        this.#dismiss()
        this.#rememberFailure()
        this.#showStatus("No se pudo recuperar la sugerencia.", true)
      }
    }
  }

  #accept(event) {
    if (event.key !== "Enter" || event.shiftKey || event.ctrlKey || event.metaKey || event.altKey || event.isComposing || this.#composing || event.keyCode === 229 || event.repeat) return
    if (!this.#proposal || this.#proposal.expires <= Date.now() || !this.#empty || this.#savedComment || !this.inputTarget.contains(event.target) || !event.target.closest("[contenteditable]") || !event.target.contains(document.activeElement)) return
    event.preventDefault()
    event.stopImmediatePropagation()
    const paragraph = document.createElement("p")
    paragraph.textContent = this.#proposal.text
    this.#dismiss()
    this.inputTarget.value = paragraph.outerHTML
    this.inputTarget.dispatchEvent(new CustomEvent("lexxy:change", { bubbles: true }))
  }

  #dismiss() {
    clearTimeout(this.#deadline)
    if (this.kindValue === "comment" && this.#stored) this.#store({ ...this.#stored, dismissed: true })
    this.#subscription?.unsubscribe()
    this.#subscription = null
    this.#active = null
    this.#proposal = null
    this.#renderPlaceholder()
    this.#showStatus("")
  }

  #renderPlaceholder() {
    if (!this.#input) return
    if (this.kindValue === "title") {
      const placeholder = this.#preparing ? "Sugiriendo título..." : this.#titlePlaceholder
      if (this.#input.getAttribute("placeholder") !== placeholder) this.#input.setAttribute("placeholder", placeholder)
      return
    }
    if (this.kindValue !== "comment") return
    const placeholder = this.#proposal && this.#empty ? `${this.#proposal.text}\nEnter para aceptar` : this.#input.dataset.aiSuggestionPlaceholder || ""
    for (const element of [ this.#input, this.#input.querySelector("[contenteditable]") ]) {
      if (element && element.getAttribute("placeholder") !== placeholder) element.setAttribute("placeholder", placeholder)
    }
  }

  #showStatus(text, retry = false) {
    if (this.kindValue === "title" && this.#input) {
      this.#preparing = !!text && !retry
      this.#renderPlaceholder()
    }
    if (this.hasStatusTarget) { this.statusTarget.textContent = text; this.statusTarget.hidden = !text }
    if (this.hasRetryTarget) this.retryTarget.hidden = !retry
  }

  get #key() { return `ai-suggestion:${this.userValue}:${this.urlValue}:${this.kindValue}` }

  get #stored() {
    try {
      const saved = JSON.parse(sessionStorage.getItem(this.#key))
      if (saved?.token && saved.expires > Date.now()) return saved
      sessionStorage.removeItem(this.#key)
    } catch { sessionStorage.removeItem(this.#key) }
    return null
  }

  #store(record) { sessionStorage.setItem(this.#key, JSON.stringify(record)) }
  #rememberFailure() {
    if (this.kindValue === "comment" && this.#stored) this.#store({ ...this.#stored, failed: true })
  }

  get #empty() { return this.kindValue === "title" ? !this.inputTarget.value.trim() : !this.#hasContent(this.inputTarget.value) }
  get #savedComment() {
    const saved = this.kindValue === "comment" && this.hasLocalKeyValue && localStorage.getItem(this.localKeyValue)
    return saved && this.#hasContent(saved)
  }
  #text(html) { return new DOMParser().parseFromString(html || "", "text/html").body.textContent.trim() }
  #hasContent(html) {
    const content = new DOMParser().parseFromString(html || "", "text/html")
    return !!(content.body.textContent.trim() || content.querySelector("action-text-attachment, img, video, audio, table, hr"))
  }
}
