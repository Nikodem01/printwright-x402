import { Controller } from "@hotwired/stimulus"

// The maintained wallet SDK is intentionally lazy: browsing and search do not
// pay its bundle cost. A connect or checkout action loads the local, digested
// module and then shares the initialized wallet with every checkout controller.
export default class extends Controller {
  static values = { moduleUrl: String }

  connect() {
    window.loadPrintwrightWallet = () => this.load()
  }

  disconnect() {
    delete window.loadPrintwrightWallet
  }

  async connectWallet() {
    try {
      const wallet = await this.load()
      await wallet.connect()
    } catch (error) {
      this.report(error)
    }
  }

  async disconnectWallet() {
    try {
      const wallet = await this.load()
      await wallet.disconnect()
    } catch (error) {
      this.report(error)
    }
  }

  load() {
    this.loading ||= import(this.moduleUrlValue).then(() => window.PrintwrightWalletReady)
    return this.loading
  }

  report(error) {
    window.dispatchEvent(new CustomEvent("printwright:wallet-change", {
      detail: { accountId: null, error: error?.message || "Wallet unavailable" },
    }))
  }
}
