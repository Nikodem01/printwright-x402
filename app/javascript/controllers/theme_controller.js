import { Controller } from "@hotwired/stimulus"

const STORAGE_KEY = "printwright-theme"

export default class extends Controller {
  static targets = ["button"]

  connect() {
    this.refresh = this.refresh.bind(this)
    this.themeQuery = window.matchMedia("(prefers-color-scheme: dark)")
    this.themeQuery.addEventListener("change", this.refresh)
    this.refresh()
  }

  disconnect() {
    this.themeQuery?.removeEventListener("change", this.refresh)
  }

  toggle() {
    const theme = this.currentTheme() === "dark" ? "light" : "dark"
    document.documentElement.dataset.theme = theme

    try {
      localStorage.setItem(STORAGE_KEY, theme)
    } catch (_error) {}

    this.refresh()
    document.dispatchEvent(new CustomEvent("theme:change", { detail: { theme } }))
  }

  refresh() {
    const dark = this.currentTheme() === "dark"
    this.buttonTarget.textContent = dark ? "Light mode" : "Dark mode"
    this.buttonTarget.setAttribute("aria-label", dark ? "Switch to light mode" : "Switch to dark mode")
    this.buttonTarget.setAttribute("aria-pressed", dark.toString())
  }

  currentTheme() {
    const selected = document.documentElement.dataset.theme
    if (selected === "light" || selected === "dark") return selected
    return this.themeQuery.matches ? "dark" : "light"
  }
}
