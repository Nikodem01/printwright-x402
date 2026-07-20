import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.observer = new ResizeObserver(() => this.measure())
    this.observer.observe(this.element)
    this.measure()

    requestAnimationFrame(() => this.alignAnchor())
  }

  disconnect() {
    this.observer?.disconnect()
  }

  measure() {
    document.documentElement.style.setProperty("--sticky-header-height", `${this.element.offsetHeight}px`)
  }

  alignAnchor() {
    if (window.location.hash !== "#models") return

    document.querySelector("#models")?.scrollIntoView({ block: "start" })
  }
}
