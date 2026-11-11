import { Controller } from "@hotwired/stimulus"
import { nextFrame } from "helpers/timing_helpers"

const SAVE_DELAY = 300

// Keeps an unsent draft in localStorage. The draft is the text the person
// still has to send: once a submission succeeds, an editor holding exactly that
// content has no draft, so a later restore cannot bring the sent text back.
export default class extends Controller {
  static targets = ["input"]
  static values = { key: String, legacyKey: String }

  #saveTimer = null
  #submittedContent = null
  #sentContent = null

  connect() {
    this.restoreContent()
  }

  disconnect() {
    if (this.#saveTimer) this.#saveNow()
  }

  save() {
    clearTimeout(this.#saveTimer)
    this.#saveTimer = setTimeout(() => this.#saveNow(), SAVE_DELAY)
  }

  // The draft becomes exactly the submitted content until the response arrives.
  submitStart() {
    this.#cancelSave()
    this.#submittedContent = this.inputTarget.value
    this.#store(this.#submittedContent)
  }

  submit({ detail: { success } }) {
    this.#sentContent = success ? this.#submittedContent : null
    this.#submittedContent = null
    this.#saveNow()
  }

  async restoreContent() {
    await nextFrame()
    let savedContent = this.#read()

    if (savedContent) {
      savedContent = `<div>${savedContent}</div>` // temporary for old markdown saves
      this.inputTarget.value = savedContent
      this.#triggerChangeEvent(savedContent)
    }
  }

  // Private

  #saveNow() {
    this.#cancelSave()
    const content = this.inputTarget.value

    if (content === this.#sentContent) {
      this.#clear()
    } else {
      this.#store(content)
    }
  }

  #store(content) {
    if (content && !this.inputTarget.isEmpty) {
      this.#write(content)
    } else {
      this.#clear()
    }
  }

  #cancelSave() {
    clearTimeout(this.#saveTimer)
    this.#saveTimer = null
  }

  // Handy #2304: a browser that refuses storage (private mode, a full quota)
  // keeps the editor working; the draft just is not kept.
  #read() {
    try {
      const saved = localStorage.getItem(this.keyValue)
      if (saved || !this.hasLegacyKeyValue) return saved

      const legacy = localStorage.getItem(this.legacyKeyValue)
      if (legacy) {
        localStorage.setItem(this.keyValue, legacy)
        localStorage.removeItem(this.legacyKeyValue)
      }
      return legacy
    } catch {
      return null
    }
  }

  #write(content) {
    try { localStorage.setItem(this.keyValue, content) } catch {}
  }

  #clear() {
    try { localStorage.removeItem(this.keyValue) } catch {}
  }

  #triggerChangeEvent(newValue) {
    if (this.inputTarget.tagName === "LEXXY-EDITOR") {
      this.inputTarget.dispatchEvent(new CustomEvent('lexxy:change', {
        bubbles: true,
        detail: {
          previousContent: '',
          newContent: newValue
        }
      }))
    }
  }
}
