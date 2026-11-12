import { Controller } from "@hotwired/stimulus"
import { nextFrame } from "helpers/timing_helpers"

const SAVE_DELAY = 300

// Keeps an unsent draft in localStorage. The draft is the text the person
// still has to send: once a submission succeeds, an editor holding exactly that
// content has no draft, so a later restore cannot bring the sent text back.
export default class extends Controller {
  static targets = ["input"]
  static values = { key: String }

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
    let savedContent = localStorage.getItem(this.keyValue)

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
      localStorage.setItem(this.keyValue, content)
    } else {
      this.#clear()
    }
  }

  #cancelSave() {
    clearTimeout(this.#saveTimer)
    this.#saveTimer = null
  }

  #clear() {
    localStorage.removeItem(this.keyValue)
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
