import { Controller } from "@hotwired/stimulus"

// Handy: counts a number up from zero when it appears, for the leaderboard.
export default class extends Controller {
  static values = { value: Number, duration: { type: Number, default: 900 } }

  connect() {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches || this.valueValue <= 0) return

    const format = new Intl.NumberFormat()
    const start = performance.now()

    const step = (now) => {
      const progress = Math.min((now - start) / this.durationValue, 1)
      const eased = 1 - Math.pow(1 - progress, 3)
      this.element.textContent = format.format(Math.round(this.valueValue * eased))
      if (progress < 1) this.frame = requestAnimationFrame(step)
    }
    this.frame = requestAnimationFrame(step)
  }

  disconnect() {
    cancelAnimationFrame(this.frame)
    this.element.textContent = new Intl.NumberFormat().format(this.valueValue)
  }
}
