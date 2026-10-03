import { Controller } from "@hotwired/stimulus"

// Remembers the last state of a checkbox in this browser, under keyValue.
export default class extends Controller {
  static values = { key: String }

  connect() {
    const saved = this.#read()
    if (saved !== null) this.element.checked = saved === "true"
  }

  save() {
    this.#write(String(this.element.checked))
  }

  #read() {
    try {
      return localStorage.getItem(this.keyValue)
    } catch {
      return null
    }
  }

  #write(value) {
    try {
      localStorage.setItem(this.keyValue, value)
    } catch {
      // Storage unavailable (private mode, blocked site data): keep the default.
    }
  }
}
