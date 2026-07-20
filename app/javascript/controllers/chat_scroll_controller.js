import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.scrollToLatest()
    this.observer = new MutationObserver(() => this.scrollToLatest())
    this.observer.observe(this.element, { childList: true })
  }

  disconnect() {
    this.observer?.disconnect()
  }

  scrollToLatest() {
    requestAnimationFrame(() => {
      this.element.scrollTop = this.element.scrollHeight
    })
  }
}
