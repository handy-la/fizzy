import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  preserveNotice(event) {
    const newElement = event.detail.newElement

    if (event.target === this.element && newElement?.id === this.element.id &&
        this.element.querySelector(".approval-toast") && !newElement.querySelector(".approval-toast")) {
      event.preventDefault()
    }
  }
}
