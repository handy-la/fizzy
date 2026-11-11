import { Controller } from "@hotwired/stimulus"
import { getMetaContent } from "helpers/meta_helpers"

// Handy #2304: posts one reply through the card's own comment endpoint and
// moves on only when the server confirms it.
//
// Every reply carries a client token until the server settles it: a second
// click, a retry after a timeout or a lost answer reuse it, and the server
// returns the comment that already landed instead of posting it twice. Before posting it
// reads the card's verdict again; if the request changed while the person
// wrote, it warns once and keeps the draft.
const TIMEOUT = 20_000

export default class extends Controller {
  static targets = [ "input", "submit", "notice", "error" ]
  static values = { stateUrl: String, fingerprint: String, nextUrl: String, draftKey: String, tokenKey: String }

  #busy = false
  #acknowledged = false
  #attempt = null

  async submit(event) {
    event.preventDefault()
    event.stopImmediatePropagation()
    if (this.#busy || this.inputTarget.isEmpty) return

    this.#busy = true
    this.submitTarget.disabled = true
    this.#hide(this.errorTarget)

    try {
      if (await this.#changed()) return
      await this.#post()
    } finally {
      this.#busy = false
      if (this.element.isConnected) this.submitTarget.disabled = this.inputTarget.isEmpty
    }
  }

  edited() {
    this.#hide(this.errorTarget)
  }

  // A live refresh of the page changed what the card asks.
  revalidate() {
    const state = document.getElementById("power_through_state")
    if (state && state.dataset.fingerprint !== this.fingerprintValue && !this.#acknowledged) {
      this.#show(this.noticeTarget, this.#changeMessage(state.dataset.status))
    }
  }

  // Private

  async #changed() {
    if (this.#acknowledged) return false

    try {
      const response = await this.#fetch(this.stateUrlValue, { headers: { Accept: "application/json" } })
      if (!response.ok) return false

      const state = await response.json()
      if (state.fingerprint === this.fingerprintValue) return false

      this.#acknowledged = true
      this.#show(this.noticeTarget, `${this.#changeMessage(state.status)} Pulsa «Enviar y siguiente» otra vez para enviar tu respuesta.`)
      return true
    } catch {
      return false
    }
  }

  async #post() {
    const body = new FormData(this.element)
    const html = body.get("comment[body]") || ""
    const attempt = this.#attemptFor(html)
    body.set("comment[client_token]", attempt.token)

    let response
    try {
      response = await this.#fetch(this.element.action, {
        method: "POST",
        body,
        headers: { Accept: "application/json", "X-CSRF-Token": getMetaContent("csrf-token") || "" }
      })
    } catch {
      this.#show(this.errorTarget, "No sabemos si tu respuesta se publicó: la conexión falló o tardó demasiado. Tu texto sigue aquí. Reintentar es seguro: no se duplica.")
      return
    }

    if (response.status === 200 && attempt.html !== html) {
      this.#settle()
      this.#show(this.noticeTarget, "Tu respuesta anterior ya estaba publicada. Los cambios que hiciste después no se enviaron: revisa el contexto antes de enviar otra.")
    } else if (response.ok) {
      this.#done()
    } else {
      if (response.status < 500) this.#settle()
      this.#show(this.errorTarget, `No se publicó tu respuesta (error ${response.status}). Tu texto sigue aquí.`)
    }
  }

  #done() {
    this.#settle()
    this.#forget(this.draftKeyValue)
    this.#show(this.noticeTarget, "Respuesta publicada.")
    Turbo.visit(this.nextUrlValue)
  }

  // One token per reply until the server settles it: an attempt whose answer
  // was lost keeps its token even if the text is edited, so a retry can never
  // post a second comment next to one that already landed. It lives in memory
  // and, when the browser allows storage, across reloads.
  #attemptFor(html) {
    const saved = this.#attempt || this.#read(this.tokenKeyValue)
    if (saved?.token) return (this.#attempt = saved)

    const token = "pt-" + Array.from(crypto.getRandomValues(new Uint8Array(16)), byte => byte.toString(16).padStart(2, "0")).join("")
    this.#attempt = { token, html }
    this.#write(this.tokenKeyValue, this.#attempt)
    return this.#attempt
  }

  #settle() {
    this.#attempt = null
    this.#forget(this.tokenKeyValue)
  }

  #fetch(url, options) {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), TIMEOUT)
    return fetch(url, { credentials: "same-origin", ...options, signal: controller.signal }).finally(() => clearTimeout(timer))
  }

  #changeMessage(status) {
    return status === "none"
      ? "La tarjeta cambió mientras escribías y ya no espera una respuesta. Revisa el contexto: tu borrador sigue aquí."
      : "La solicitud cambió mientras escribías. Revisa lo que pide ahora: tu borrador sigue aquí."
  }

  #show(element, message) {
    element.textContent = message
    element.hidden = false
  }

  #hide(element) {
    element.hidden = true
    element.textContent = ""
  }

  #read(key) {
    try { return JSON.parse(localStorage.getItem(key)) } catch { return null }
  }

  #write(key, value) {
    try { localStorage.setItem(key, JSON.stringify(value)) } catch {}
  }

  #forget(key) {
    try { localStorage.removeItem(key) } catch {}
  }
}
