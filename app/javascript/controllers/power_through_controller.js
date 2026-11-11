import { Controller } from "@hotwired/stimulus"

// Handy #2304: the Power Through page. It remembers the chosen stages in this
// browser only, per account, person and board, and moves between cards with
// the keyboard without ever catching a key typed into a field.
const VERSION = 1

export default class extends Controller {
  static targets = [ "previous", "next", "skip", "context", "stages" ]
  static values = { preferences: Object, explicit: Boolean }

  connect() {
    if (this.explicitValue) {
      this.#store(this.preferencesValue.selected)
    } else {
      this.#restore()
    }
  }

  rememberStages(event) {
    const chosen = new FormData(event.target).getAll("stages[]")
    this.#store(chosen)
  }

  toggleContext() {
    if (!this.hasContextTarget) return

    this.contextTarget.open = !this.contextTarget.open
    if (this.contextTarget.open) this.contextTarget.querySelector("summary")?.focus()
  }

  navigate(event) {
    if (this.#editing(event) || event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return

    const handler = {
      j: () => this.#follow(this.hasNextTarget && this.nextTarget),
      k: () => this.#follow(this.hasPreviousTarget && this.previousTarget),
      c: () => this.toggleContext(),
      r: () => this.#focusEditor()
    }[event.key.toLowerCase()]

    if (handler) {
      event.preventDefault()
      handler()
    }
  }

  // Private

  #editing(event) {
    const target = event.target
    return target.isContentEditable || target.closest?.("input, textarea, select, [contenteditable], lexxy-editor, dialog[open]")
  }

  #follow(link) {
    link?.click()
  }

  #focusEditor() {
    this.element.querySelector("lexxy-editor [contenteditable]")?.focus()
  }

  get #key() {
    const { account, user, board } = this.preferencesValue
    return `power-through:v${VERSION}:${account}:${user}:${board}`
  }

  #restore() {
    const saved = this.#valid(this.#read())
    if (!saved.length || this.#same(saved, this.preferencesValue.selected)) return

    const url = new URL(window.location.href)
    url.searchParams.set("stages", saved.join(","))
    url.searchParams.delete("card")
    Turbo.visit(url.toString(), { action: "replace" })
  }

  // Stages deleted since they were saved are dropped; nothing valid left
  // means the board's default.
  #valid(record) {
    if (record?.version !== VERSION || !Array.isArray(record.stages)) return []
    return record.stages.filter(id => this.preferencesValue.stages.includes(id))
  }

  #same(a, b) {
    return a.length === b.length && a.every(id => b.includes(id))
  }

  #read() {
    try {
      const raw = localStorage.getItem(this.#key)
      return raw ? JSON.parse(raw) : null
    } catch {
      this.#forget()
      return null
    }
  }

  #store(stages) {
    const valid = stages.filter(id => this.preferencesValue.stages.includes(id))
    try {
      localStorage.setItem(this.#key, JSON.stringify({ version: VERSION, stages: valid }))
    } catch {}
  }

  #forget() {
    try { localStorage.removeItem(this.#key) } catch {}
  }
}
