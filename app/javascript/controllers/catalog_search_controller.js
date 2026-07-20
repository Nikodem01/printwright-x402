import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "results", "clear"]
  static values = { url: String }

  connect() {
    this.syncClear()
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  queue() {
    clearTimeout(this.timer)
    this.syncClear()

    const query = this.inputTarget.value.trim()
    if (query.length < 2) return this.dismiss()

    this.timer = setTimeout(() => {
      this.resultsTarget.src = `${this.urlValue}?q=${encodeURIComponent(query)}`
    }, 180)
  }

  loaded() {
    this.resultsTarget.hidden = false
    this.inputTarget.setAttribute("aria-expanded", "true")
  }

  clear() {
    clearTimeout(this.timer)
    this.inputTarget.value = ""
    this.syncClear()
    this.dismiss()
    this.inputTarget.focus()
  }

  submit(event) {
    event.preventDefault()
    this.dismiss()

    const url = new URL(event.currentTarget.action)
    url.search = new URLSearchParams(new FormData(event.currentTarget)).toString()
    url.hash = "models"

    if (window.Turbo) window.Turbo.visit(url.toString())
    else window.location.assign(url.toString())
  }

  dismiss(event) {
    if (event && this.element.contains(event.target)) return

    this.resultsTarget.hidden = true
    this.inputTarget.setAttribute("aria-expanded", "false")
  }

  keydown(event) {
    if (event.key === "Escape") {
      this.dismiss()
      return
    }

    if (event.key !== "ArrowDown") return

    const firstResult = this.resultsTarget.querySelector("a")
    if (!firstResult || this.resultsTarget.hidden) return

    event.preventDefault()
    event.stopPropagation()
    firstResult.focus()
  }

  navigate(event) {
    if (!["ArrowDown", "ArrowUp"].includes(event.key)) return

    const links = Array.from(this.resultsTarget.querySelectorAll("a"))
    const index = links.indexOf(document.activeElement)
    if (index < 0) return

    event.preventDefault()
    const direction = event.key === "ArrowDown" ? 1 : -1
    links[(index + direction + links.length) % links.length].focus()
  }

  syncClear() {
    this.clearTarget.hidden = this.inputTarget.value.length === 0
  }
}
