import { Controller } from "@hotwired/stimulus"
import { getMetaContent } from "helpers/meta_helpers"

// Handy #2304: posts one reply through the card's own comment endpoint and
// moves on only when the server confirms it.
//
// Every reply carries a client token until the server settles it: a second
// click, a retry after a timeout or a lost answer reuse it, and the server
// returns the comment that already landed instead of posting it twice.
//
// Before every post it reads the card's verdict again: if the request changed
// since the person last saw it, it warns and keeps the draft, and if the
// verdict cannot be read it does not post at all.
const TIMEOUT = 20_000

export default class extends Controller {
  static targets = [ "input", "submit", "notice", "error" ]
  static values = { stateUrl: String, fingerprint: String, draftKey: String, tokenKey: String, cardId: String }

  #busy = false
  #landedElsewhere = null
  #seen = null
  #attempt = null

  connect() {
    this.#seen = this.fingerprintValue
  }

  async submit(event) {
    event.preventDefault()
    event.stopImmediatePropagation()
    if (this.#busy || this.inputTarget.isEmpty) return

    this.#busy = true
    this.submitTarget.disabled = true
    this.#hide(this.errorTarget)

    try {
      if (await this.#verified()) await this.#post()
    } finally {
      this.#busy = false
      if (this.element.isConnected) this.submitTarget.disabled = this.inputTarget.isEmpty
    }
  }

  edited() {
    this.#hide(this.errorTarget)
  }

  // An earlier editor of this same card, gone since, had its post confirmed:
  // this editor may show the reply it sent, restored from the draft. Its
  // token is settled, so sending that text again would post it twice. An
  // editor still checking the verdict before its own post remembers what
  // landed, so that post is not sent.
  reconcile({ detail: { cardId, sent, landedNow } }) {
    if (cardId !== this.cardIdValue || !this.element.isConnected) return
    if (this.#busy) {
      if (landedNow) this.#landedElsewhere = sent
      return
    }

    if (landedNow && this.inputTarget.value === sent) {
      this.#clearPublished()
    } else {
      this.#show(this.noticeTarget, landedNow
        ? "Tu respuesta anterior ya se publicó. Lo que escribiste después sigue aquí, sin publicar."
        : "Ya estaba publicada una versión anterior de tu respuesta. El texto del editor no se envió: revisa el contexto antes de enviar otra.")
    }
  }

  // A live refresh of the page changed what the card asks.
  revalidate() {
    const state = document.getElementById("power_through_state")
    if (state && state.dataset.fingerprint !== this.#seen) {
      this.#show(this.noticeTarget, this.#changeMessage(state.dataset.status))
    }
  }

  // Private

  // True only when the card's current verdict is the one the person saw. A
  // change is shown and becomes the one seen, so the next press sends; a
  // verdict that cannot be read stops the post.
  async #verified() {
    let state
    try {
      const response = await this.#fetch(this.stateUrlValue, { headers: { Accept: "application/json" } })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      state = await response.json()
    } catch {
      this.#show(this.errorTarget, "No pude comprobar si la tarjeta cambió, así que no envié tu respuesta. Tu texto sigue aquí: intenta otra vez.")
      return false
    }

    if (state.fingerprint === this.#seen) return true

    this.#seen = state.fingerprint
    this.#show(this.noticeTarget, `${this.#changeMessage(state.status)} Pulsa «Enviar y siguiente» otra vez para enviar tu respuesta.`)
    return false
  }

  async #post() {
    const body = new FormData(this.element)
    const sent = body.get("comment[body]") || ""
    if (sent === this.#landedElsewhere) {
      this.#landedElsewhere = null
      this.#clearPublished()
      return
    }
    body.set("comment[client_token]", this.#token())

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

    if (response.status === 201 || (response.status === 200 && response.headers.has("Comment-Replay"))) {
      this.#confirmed(response, sent)
    } else if (response.ok) {
      // A redirect (an expired session) or any other page is no confirmation:
      // the token stays, so a retry after signing in cannot duplicate.
      this.#show(this.errorTarget, "No pude confirmar si tu respuesta se publicó: la sesión pudo haber terminado. Tu texto sigue aquí. Recarga la página y vuelve a enviar: no se duplica.")
    } else {
      // A rejection speaks for this attempt only: an earlier one under the
      // same token may have landed while its answer was lost. The token is
      // kept until the server confirms a comment, so a retry replays it
      // instead of posting a second one.
      this.#show(this.errorTarget, `Este envío no se publicó (error ${response.status}). Tu texto sigue aquí. Reintentar es seguro: no se duplica.`)
    }
  }

  // The status and headers are the confirmation; the body is never needed.
  // What landed is exactly the HTML this request sent, unless the server
  // answers a replay with an earlier version under the same token. The page
  // moves on only when what landed is exactly what the editor holds now: any
  // other text (typed during the post, or never sent) stays in the editor.
  #confirmed(response, sent) {
    this.#settle()
    const landedNow = response.status === 201 || response.headers.get("Comment-Replay") === "same"

    // The person left this card while the post was on its way: this editor
    // is gone, and the stored draft may now belong to a newer editor of the
    // same card. Only a draft that is exactly what landed is cleared, and the
    // newer editor, if there is one, reconciles what it shows.
    if (!this.element.isConnected) {
      if (landedNow && this.#readRaw(this.draftKeyValue) === sent) this.#forget(this.draftKeyValue)
      window.dispatchEvent(new CustomEvent("power-through:confirmed", { detail: { cardId: this.cardIdValue, sent, landedNow } }))
      return
    }

    if (landedNow && this.inputTarget.value === sent) {
      // The next card can be this same one (an approval stage keeps it
      // queued for review), and its permanent editor survives the visit:
      // a published reply must not stay there, ready to post again.
      this.inputTarget.value = ""
      this.#forget(this.draftKeyValue)
      this.#show(this.noticeTarget, "Respuesta publicada.")
      if (this.#focused) Turbo.visit(this.#nextUrl)
    } else {
      this.#write(this.draftKeyValue, this.inputTarget.value, { raw: true })
      this.#show(this.noticeTarget, landedNow
        ? "Se publicó tu respuesta. Lo que escribiste mientras se enviaba sigue aquí, sin publicar."
        : "Ya estaba publicada una versión anterior de tu respuesta. El texto del editor no se envió: revisa el contexto antes de enviar otra.")
    }
  }

  #clearPublished() {
    this.inputTarget.value = ""
    this.#forget(this.draftKeyValue)
    this.submitTarget.disabled = true
    this.#show(this.noticeTarget, "Tu respuesta ya se publicó.")
  }

  // The person may have gone on to another card while the post was on its
  // way: then this card's confirmation keeps what landed and moves no one.
  get #focused() {
    return this.element.isConnected && document.getElementById("power_through_state")?.dataset.cardId === this.cardIdValue
  }

  // Read from the page as it is now, not from this editor: the editor is
  // permanent and keeps the attributes of the page that first drew it, so a
  // change of stages would otherwise send the person back to the old ones.
  get #nextUrl() {
    return document.getElementById("power_through_state")?.dataset.nextUrl || window.location.href
  }

  // One token per reply until the server settles it: an attempt whose answer
  // was lost keeps its token even if the text is edited, so a retry can never
  // post a second comment next to one that already landed. It lives in memory
  // and, when the browser allows storage, across reloads.
  #token() {
    this.#attempt ||= this.#read(this.tokenKeyValue)
    if (!this.#attempt?.token) {
      const token = "pt-" + Array.from(crypto.getRandomValues(new Uint8Array(16)), byte => byte.toString(16).padStart(2, "0")).join("")
      this.#attempt = { token }
      this.#write(this.tokenKeyValue, this.#attempt)
    }
    return this.#attempt.token
  }

  #settle() {
    this.#attempt = null
    this.#landedElsewhere = null
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

  #readRaw(key) {
    try { return localStorage.getItem(key) } catch { return null }
  }

  #write(key, value, { raw = false } = {}) {
    try { localStorage.setItem(key, raw ? value : JSON.stringify(value)) } catch {}
  }

  #forget(key) {
    try { localStorage.removeItem(key) } catch {}
  }
}
