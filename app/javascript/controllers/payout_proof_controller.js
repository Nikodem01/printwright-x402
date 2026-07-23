import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button", "signature", "status"]
  static values = { account: String, message: String }

  async sign(event) {
    event.preventDefault()
    this.buttonTarget.disabled = true
    this.statusTarget.textContent = "Opening wallet…"

    try {
      if (!window.loadPrintwrightWallet) throw new Error("Wallet connection is not configured")
      const wallet = await window.loadPrintwrightWallet()
      const signed = await wallet.signMessage(this.messageValue, this.accountValue)
      this.signatureTarget.value = signed.signatureMap
      this.statusTarget.textContent = "Signed. Verifying wallet control…"
      this.element.requestSubmit()
    } catch (error) {
      this.buttonTarget.disabled = false
      this.statusTarget.textContent = error?.message || "The wallet could not sign this challenge"
    }
  }
}
