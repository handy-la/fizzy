import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"

const LABELS = {
  scheduled: "Programado", running: "En curso", waiting_ci: "Esperando CI", waiting_resource: "Esperando recurso",
  deferred: "Diferido", lock_busy: "Lock ocupado", noop: "Sin cambios", failed: "Último intento fallido",
  no_signal: "Sin señal", scheduler_missing: "Sin programador", disabled: "Deshabilitado"
}
const RESULTS = { succeeded: "Completado", noop: "Sin cambios", failed: "Fallido", cancelled: "Cancelado" }

export default class extends Controller {
  static targets = [ "button", "label", "icon", "path", "next", "nextLabel", "detail", "fields" ]
  static values = { board: String, stage: String, snapshot: Object, url: String, icons: Object }

  #state
  #subscription
  #timer
  #clock
  #request
  #generation = 0
  #pinned = false
  #touching = false
  #connected = false
  #serverOffset = 0
  #serverTime = 0

  connect() {
    this.#state ||= this.snapshotValue
    this.refresh()
    this.recover()
    this.#subscribe()
    this.#timer = setInterval(() => this.refresh(), 15_000)
    // Local display only: the clock never polls or broadcasts once per second.
    this.#clock = setInterval(() => {
      const previous = this.labelTarget.textContent
      this.#summary()
      if (previous !== this.labelTarget.textContent) this.refresh()
    }, 1000)
  }

  disconnect() {
    this.#generation++
    clearInterval(this.#timer)
    clearInterval(this.#clock)
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
    this.#summary()
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

  #summary() {
    if (!this.#state) return
    const state = this.#state
    const now = Date.now() + this.#serverOffset
    const stale = state.revision > 0 && Date.parse(state.valid_until) <= now
    const key = stale ? "stale" : state.state
    this.labelTarget.textContent = stale ? "Desactualizado" : LABELS[key] || "Sin señal"
    this.iconTarget.dataset.state = key
    this.pathTarget.setAttribute("d", this.iconsValue[key] || this.iconsValue.no_signal)
    const unavailable = stale || [ "no_signal", "scheduler_missing", "disabled" ].includes(state.state)
    const event = !unavailable && [ "waiting_ci", "waiting_resource", "lock_busy" ].includes(state.state) && state.expected_event
    const next = Date.parse(state.next_run_at)
    let value = "No disponible"
    if (event) value = state.expected_event
    else if (!unavailable && Number.isFinite(next)) {
      const seconds = Math.ceil((next - now) / 1000)
      value = seconds <= 0 ? "Pendiente" : [ Math.floor(seconds / 3600), Math.floor(seconds % 3600 / 60), seconds % 60 ].map(number => String(number).padStart(2, "0")).join(":")
    } else if (state.state === "disabled") value = "Sin programación"
    this.nextLabelTarget.textContent = event ? "Evento" : "Próximo"
    this.nextTarget.textContent = value
    this.nextTarget.title = value
    this.buttonTarget.setAttribute("aria-label", `Salud del tick: ${this.labelTarget.textContent}. ${this.nextLabelTarget.textContent}: ${value}`)
  }

  pointing(event) {
    this.#touching = event.pointerType === "touch" || event.pointerType === "pen"
  }

  hover(event) {
    if (event.pointerType === "mouse") this.show()
  }

  show(event) {
    // A touch opens on click. Opening on its synthetic hover/focus can place
    // the popover over the finger before touchend and cancel the activation.
    if (event?.type === "focusin" && this.#touching && !this.buttonTarget.matches(":focus-visible")) return
    if (!this.detailTarget.matches(":popover-open")) this.detailTarget.showPopover()
    const anchor = this.buttonTarget.getBoundingClientRect()
    const { width, height } = this.detailTarget.getBoundingClientRect()
    const margin = 8
    let left = Math.max(margin, Math.min(anchor.left, innerWidth - width - margin))
    let top = Math.max(margin, Math.min(anchor.bottom + margin, innerHeight - height - margin))

    // Keep the anchor clear when the tall detail fits beside a folded rail.
    // Otherwise pointerleave would close it as soon as it covers the button.
    if (anchor.bottom + margin + height > innerHeight && anchor.top - margin < height) {
      if (anchor.left >= width + margin) left = anchor.left - width - margin
      else if (anchor.right + margin + width <= innerWidth) left = anchor.right + margin
    } else if (anchor.bottom + margin + height > innerHeight) {
      top = anchor.top - height - margin
    }
    this.detailTarget.style.left = `${left}px`
    this.detailTarget.style.top = `${top}px`
  }

  hideUnlessPinned() {
    if (!this.#pinned) this.hide()
  }

  hide() {
    this.#pinned = false
    if (this.hasDetailTarget && this.detailTarget.matches(":popover-open")) this.detailTarget.hidePopover()
  }

  toggle(event) {
    this.#touching = false
    event.preventDefault()
    event.stopPropagation()
    if (this.#pinned) this.hide()
    else { this.show(); this.#pinned = true }
  }

  keyboard(event) {
    this.#touching = false
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
