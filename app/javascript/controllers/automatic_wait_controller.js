import { Controller } from "@hotwired/stimulus"

// The automatic-wait clock on a card preview. Hover and focus show the reasons;
// a click, a tap, Enter or Space pins them open; Escape, a second activation or
// a tap elsewhere closes them. As the clock moves it recomputes the
// time-dependent texts with the rules of AutomaticWaitsHelper: a review date
// counts down, then reads "pending", then "overdue", and a wait past its
// validity reads as out of date. It only reads: it never writes to the server.
const HUMAN_TEXT = {
  required: "Requiere intervención humana",
  pending: "Hay una decisión humana pendiente",
  stale: "Seguimiento desactualizado",
  unknown: "Sin evidencia sobre intervención humana",
  not_required: "No requiere intervención humana"
}

const REFRESH_INTERVAL = 15_000

export default class extends Controller {
  static targets = [ "button", "popover", "human", "wait" ]
  static values = { human: String, overdueAfter: Number }

  #timer
  #pinned = false

  connect() {
    this.refresh()
    this.#timer = setInterval(() => this.refresh(), REFRESH_INTERVAL)
  }

  disconnect() {
    clearInterval(this.#timer)
    this.#pinned = false
  }

  humanValueChanged() {
    this.refresh()
  }

  waitTargetConnected() {
    this.refresh()
  }

  show() {
    if (!this.hasPopoverTarget || this.#isOpen) return

    this.popoverTarget.showPopover()
    this.#position()
  }

  hideUnlessPinned() {
    if (!this.#pinned) this.hide()
  }

  dismiss(event) {
    if (this.hasPopoverTarget && this.#isOpen) event.stopPropagation()
    this.hide()
  }

  hide() {
    this.#pinned = false
    if (this.hasPopoverTarget && this.#isOpen) this.popoverTarget.hidePopover()
  }

  // Enter and Space are handled here, not by the button's native click: the
  // board's navigable list turns Enter into a click on the card's link.
  toggle(event) {
    event.preventDefault()
    event.stopPropagation()

    if (this.#pinned) {
      this.hide()
    } else {
      this.show()
      this.#pinned = true
    }
  }

  popoverToggled(event) {
    const open = event.newState === "open"
    if (!open) this.#pinned = false
    if (this.hasButtonTarget) this.buttonTarget.setAttribute("aria-expanded", open)
  }

  refresh() {
    const now = Date.now()
    let anyStale = false

    this.waitTargets.forEach(wait => {
      const stale = Date.parse(wait.dataset.validUntil) <= now
      anyStale ||= stale

      const staleLabel = wait.querySelector("[data-role=stale]")
      if (staleLabel) staleLabel.hidden = !stale

      const review = wait.querySelector("[data-role=review]")
      if (review) review.textContent = this.#reviewText(wait, now)
    })

    const human = this.#human(anyStale)
    if (this.hasHumanTarget) this.humanTarget.textContent = HUMAN_TEXT[human]

    this.element.classList.forEach(name => {
      if (name.startsWith("card__automatic-waits--")) this.element.classList.remove(name)
    })
    this.element.classList.add(`card__automatic-waits--${human}`)
  }

  #human(anyStale) {
    const declared = this.humanValue
    if (declared === "required" || declared === "pending") return declared
    if (anyStale) return "stale"
    return HUMAN_TEXT[declared] ? declared : "unknown"
  }

  #reviewText(wait, now) {
    const nextCheckAt = wait.dataset.nextCheckAt
    if (!nextCheckAt) return `Espera: ${wait.dataset.expectedEvent}`

    const seconds = (Date.parse(nextCheckAt) - now) / 1000
    if (seconds > 0) return `Próxima revisión en aproximadamente ${this.#duration(seconds)}`
    if (-seconds < this.overdueAfterValue) return "Revisión pendiente"
    return "Revisión vencida"
  }

  #duration(seconds) {
    const minutes = Math.max(Math.ceil(seconds / 60), 1)
    return minutes < 60 ? `${minutes} min` : `${Math.round(minutes / 60)} h`
  }

  // The popover lives in the top layer, so it is placed against the button by
  // hand: above it when it fits, below otherwise, always inside the viewport.
  #position() {
    const margin = 8
    const anchor = this.buttonTarget.getBoundingClientRect()
    const popover = this.popoverTarget
    const { width, height } = popover.getBoundingClientRect()

    let top = anchor.top - height - margin
    if (top < margin) top = anchor.bottom + margin

    let left = anchor.right - width
    left = Math.min(Math.max(left, margin), window.innerWidth - width - margin)

    popover.style.top = `${Math.max(top, margin)}px`
    popover.style.left = `${Math.max(left, margin)}px`
  }

  get #isOpen() {
    return this.popoverTarget.matches(":popover-open")
  }
}
