import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  #observer = new MutationObserver(() => this.#decorate())
  #timers = new Map()
  #connection = 0

  connect() {
    this.#connection++
    this.element.querySelectorAll("[data-code-copy-button]").forEach(button => this.#reset(button))
    this.#decorate()
  }

  disconnect() {
    this.#connection++
    this.#observer.disconnect()
    this.#timers.forEach(timer => clearTimeout(timer))
    this.#timers.clear()
  }

  #decorate() {
    this.#observer.disconnect()

    // Mermaid replaces its source with a diagram asynchronously.
    this.element.querySelectorAll(".code-block").forEach(block => {
      if (!block.querySelector("pre")) {
        block.querySelectorAll(".code-block__toolbar, .code-block__status").forEach(control => control.remove())
        block.replaceWith(...block.childNodes)
      }
    })

    this.element.querySelectorAll("pre").forEach(pre => {
      if (!pre.closest(".code-block, lexxy-editor, [contenteditable]")) {
        const block = document.createElement("div")
        block.className = "code-block"
        const toolbar = document.createElement("div")
        toolbar.className = "code-block__toolbar"
        const button = document.createElement("button")
        button.type = "button"
        button.className = "btn code-block__copy"
        button.textContent = "Copiar"
        button.setAttribute("aria-label", "Copiar código")
        button.dataset.codeCopyButton = ""
        button.dataset.action = "mousedown->code-copy#preserveSelection click->code-copy#copy"
        const status = document.createElement("span")
        status.className = "code-block__status visually-hidden"
        status.setAttribute("role", "status")
        toolbar.append(button)
        pre.before(block)
        block.append(toolbar, pre, status)
      }
    })

    this.#observer.observe(this.element, { childList: true, subtree: true })
  }

  preserveSelection(event) {
    event.preventDefault()
  }

  async copy(event) {
    event.preventDefault()
    const button = event.currentTarget
    const block = button.closest(".code-block")
    const pre = block.querySelector("pre")
    if (!pre || button.disabled) return

    this.#reset(button)
    const connection = this.#connection
    const status = block.querySelector(".code-block__status")
    button.disabled = true

    try {
      // Read only the source, never the controls or rendered HTML. Do not trim.
      await navigator.clipboard.writeText(pre.textContent)
      if (connection !== this.#connection || !this.element.contains(button)) return
      button.textContent = "Copiado"
      button.dataset.copyState = "success"
      status.textContent = "Código copiado"
      this.#timers.set(button, setTimeout(() => this.#reset(button), 2000))
    } catch {
      if (connection !== this.#connection || !this.element.contains(button)) return
      button.dataset.copyState = "error"
      status.classList.remove("visually-hidden")
      status.textContent = "No se pudo copiar. Selecciona el código y cópialo manualmente."
    } finally {
      button.disabled = false
    }
  }

  #reset(button) {
    clearTimeout(this.#timers.get(button))
    this.#timers.delete(button)
    button.disabled = false
    button.textContent = "Copiar"
    delete button.dataset.copyState
    const status = button.closest(".code-block").querySelector(".code-block__status")
    status.textContent = ""
    status.classList.add("visually-hidden")
  }
}
