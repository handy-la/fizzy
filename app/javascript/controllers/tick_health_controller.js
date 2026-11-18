import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"

const LABELS = {
  scheduled: "Programado", running: "En curso", waiting_ci: "Esperando CI", waiting_resource: "Esperando recurso",
  deferred: "Diferido", lock_busy: "Lock ocupado", noop: "Sin cambios", failed: "Último intento fallido",
  no_signal: "Sin señal", scheduler_missing: "Sin programador", disabled: "Deshabilitado"
}
const RESULTS = { succeeded: "Completado", noop: "Sin cambios", failed: "Fallido", cancelled: "Cancelado" }

export default class extends Controller {
  static targets = [ "button", "label", "detail", "fields" ]
  static values = { board: String, stage: String, snapshot: Object, url: String }

  #state
  #subscription
  #timer
  #request
  #generation = 0
  #pinned = false
  #connected = false
  #serverOffset = 0
  #serverTime = 0

  connect() {
    this.#state ||= this.snapshotValue
    this.refresh()
    this.recover()
    this.#subscribe()
    this.#timer = setInterval(() => this.refresh(), 15_000)
  }

  disconnect() {
    this.#generation++
    clearInterval(this.#timer)
    this.#request?.abort()
    this.#subscription?.unsubscribe()
    this.hide()
  }

  async #subscribe() {
    const generation = this.#generation
    const controller = this
    try {
      const subscription = await cable.subscribeTo({ channel: "TickHealthChannel", board_id: this.boardValue }, {
        connected() { controller.#connected = true; controller.refresh(); this.perform("recover") },
        disconnected() { controller.#connected = false; controller.refresh() },
        received(data) { if (generation === controller.#generation) controller.receive(data) },
        rejected() { controller.revoke() }
      })
      if (generation !== this.#generation || !this.element.isConnected) subscription.unsubscribe()
      else this.#subscription = subscription
    } catch {
      // The evidence expires locally even without a working socket.
    }
  }

  async recover() {
    this.#request?.abort()
    const request = new AbortController()
    const generation = this.#generation
    this.#request = request
    try {
      const response = await fetch(this.urlValue, { credentials: "same-origin", headers: { Accept: "application/json" }, cache: "no-store", signal: request.signal })
      if (generation !== this.#generation || !this.element.isConnected) return
      if ([ 401, 403, 404 ].includes(response.status)) { this.revoke(); return }
      if (response.ok) {
        const snapshot = await response.json()
        if (generation === this.#generation && this.element.isConnected) this.receive(snapshot)
      }
    } catch {
      // Keep the last evidence with its original deadline, never invent success.
    }
  }

  receive(snapshot) {
    if (snapshot.board_id !== this.boardValue || !this.element.isConnected) return
    if (snapshot.error === "access_revoked") { this.revoke(); return }
    if (snapshot.schema !== 1 || snapshot.product_id !== this.#state.product_id || !Array.isArray(snapshot.stages)) return
    const serverTime = Date.parse(snapshot.server_time)
    if (Number.isFinite(serverTime) && serverTime >= this.#serverTime) {
      this.#serverTime = serverTime
      this.#serverOffset = serverTime - Date.now()
    }
    const stage = snapshot.stages.find(stage => stage.stage_id === this.stageValue && stage.column_id === this.#state.column_id)
    if (!stage) { this.revoke(); return }
    if (!Number.isSafeInteger(stage.revision) || stage.revision <= this.#state.revision) { this.refresh(); return }
    this.#state = stage
    this.element.hidden = false
    this.refresh()
  }

  revoke() {
    this.#generation++
    this.#request?.abort()
    this.hide()
    this.fieldsTarget.replaceChildren()
    this.element.hidden = true
  }

  refresh() {
    if (!this.#state) return
    const state = this.#state
    const now = Date.now() + this.#serverOffset
    const stale = state.revision > 0 && Date.parse(state.valid_until) <= now
    this.labelTarget.textContent = stale ? "Desactualizado" : LABELS[state.state] || "Sin señal"
    this.buttonTarget.setAttribute("aria-label", `Salud del tick: ${this.labelTarget.textContent}`)
    const fields = [
      [ "Estado", this.labelTarget.textContent ],
      [ "Actualización en vivo", this.#connected ? "Conectada" : "Sin conexión; se conserva la última señal" ],
      [ "Fase actual", state.phase || "No disponible" ],
      [ "Desde", state.phase_started_at ? `${this.#time(state.phase_started_at)} · ${this.#duration((now - Date.parse(state.phase_started_at)) / 1000)}` : "No disponible" ],
      [ "Último resultado", state.last_result ? `${RESULTS[state.last_result]} · ${this.#time(state.last_finished_at)}. ${state.last_reason}` : "No disponible" ],
      [ "Próxima corrida", state.next_run_at ? `${this.#time(state.next_run_at)}${Date.parse(state.next_run_at) <= now ? " · Fecha pasada; sin nueva programación" : ""}` : "No disponible" ],
      [ "Evento esperado", state.expected_event || "No disponible" ],
      [ "Duración estimada del tick", state.duration_samples >= 5 && state.duration_min_seconds != null ? `${this.#duration(state.duration_min_seconds)} – ${this.#duration(state.duration_max_seconds)} (${state.duration_samples} muestras)` : "Sin estimación" ],
      [ "Señal", state.reported_at ? `${this.#time(state.reported_at)} · ${stale ? "Fuente desactualizada" : "Vigente hasta " + this.#time(state.valid_until)}` : "Sin señal recibida" ]
    ]
    const nodes = fields.flatMap(([ label, value ]) => {
      const term = document.createElement("dt")
      const description = document.createElement("dd")
      term.textContent = label
      description.textContent = value
      return [ term, description ]
    })
    this.fieldsTarget.replaceChildren(...nodes)
    if (this.detailTarget.matches(":popover-open")) this.show()
  }

  show() {
    if (!this.detailTarget.matches(":popover-open")) this.detailTarget.showPopover()
    const anchor = this.buttonTarget.getBoundingClientRect()
    const { width, height } = this.detailTarget.getBoundingClientRect()
    this.detailTarget.style.left = `${Math.max(8, Math.min(anchor.left, innerWidth - width - 8))}px`
    this.detailTarget.style.top = `${Math.max(8, Math.min(anchor.bottom + 8, innerHeight - height - 8))}px`
  }

  hideUnlessPinned() {
    if (!this.#pinned) this.hide()
  }

  hide() {
    this.#pinned = false
    if (this.hasDetailTarget && this.detailTarget.matches(":popover-open")) this.detailTarget.hidePopover()
  }

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()
    if (this.#pinned) this.hide()
    else { this.show(); this.#pinned = true }
  }

  keyboard(event) {
    // Board navigation handles Enter and Space. The health control owns them.
    if (event.target === this.buttonTarget && [ "Enter", " " ].includes(event.key)) this.toggle(event)
    if (event.key === "Escape") { event.stopPropagation(); this.hide() }
  }

  toggled(event) {
    const open = event.newState === "open"
    this.buttonTarget.setAttribute("aria-expanded", String(open))
    if (!open) this.#pinned = false
  }

  #time(value) {
    const time = new Date(value)
    return Number.isNaN(time.getTime()) ? "No disponible" : time.toLocaleString("es-MX", { dateStyle: "short", timeStyle: "short" })
  }

  #duration(seconds) {
    const minutes = Math.max(0, Math.floor(seconds / 60))
    return minutes < 1 ? "menos de 1 min" : minutes < 60 ? `${minutes} min` : `${Math.floor(minutes / 60)} h ${minutes % 60} min`
  }
}
