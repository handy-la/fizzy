import { Controller } from "@hotwired/stimulus"

// Handy: a short burst of confetti on the leaderboard when something shipped today.
const COLORS = [ "--color-card-3", "--color-card-4", "--color-card-5", "--color-card-6", "--color-card-8", "--color-card-default" ]
const PIECES = 70

export default class extends Controller {
  connect() {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return

    this.pieces = Array.from({ length: PIECES }, (_, index) => this.#piece(index))
    this.element.append(...this.pieces)
    this.timer = setTimeout(() => this.#clear(), 4500)
  }

  disconnect() {
    clearTimeout(this.timer)
    this.#clear()
  }

  #piece(index) {
    const piece = document.createElement("span")
    piece.className = "leaderboard__confetti"
    piece.setAttribute("aria-hidden", "true")
    piece.style.setProperty("--x", `${Math.random() * 100}vw`)
    piece.style.setProperty("--drift", `${(Math.random() - 0.5) * 30}vw`)
    piece.style.setProperty("--spin", `${Math.round(Math.random() * 720)}deg`)
    piece.style.setProperty("--delay", `${Math.random() * 600}ms`)
    piece.style.setProperty("--duration", `${2200 + Math.random() * 1500}ms`)
    piece.style.background = `var(${COLORS[index % COLORS.length]})`
    return piece
  }

  #clear() {
    this.pieces?.forEach(piece => piece.remove())
    this.pieces = []
  }
}
