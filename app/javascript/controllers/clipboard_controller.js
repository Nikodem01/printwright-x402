import { Controller } from "@hotwired/stimulus"

// Copies the full on-chain fact (hash, tx id) behind a truncated display.
export default class extends Controller {
  static targets = ["source"]

  copy(event) {
    const value = event.currentTarget.dataset.clipboardFullValue || this.sourceTarget.textContent.trim()
    navigator.clipboard.writeText(value).then(() => {
      const button = event.target
      const original = button.textContent
      button.textContent = "copied ✓"
      setTimeout(() => (button.textContent = original), 1500)
    })
  }
}
