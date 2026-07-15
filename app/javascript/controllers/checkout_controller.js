import { Controller } from "@hotwired/stimulus"

// S3 checkout state machine (plan 06): idle -> quoting -> wallet -> settling
// -> success | failed. The signer is a local demo-wallet daemon; the states,
// copy and receipt are exactly what a HashPack-backed signer would use.
export default class extends Controller {
  static targets = ["offer", "button", "status", "receipt"]
  static values = { downloadUrl: String, walletUrl: { type: String, default: "http://localhost:4022" } }

  connect() {
    this.updatePrice()
  }

  updatePrice() {
    const offer = this.selectedOffer()
    if (this.hasButtonTarget && offer) {
      this.buttonTarget.textContent = `Buy license · $${(offer.dataset.priceCents / 100).toFixed(2)}`
    }
  }

  selectedOffer() {
    return this.offerTargets.find((o) => o.querySelector("input").checked) || this.offerTargets[0]
  }

  async buy() {
    const kind = this.selectedOffer().querySelector("input").value
    const url = `${this.downloadUrlValue}?license=${kind}`
    try {
      this.setState("quoting", "Fetching payment terms…")
      const leg1 = await fetch(url, { headers: { accept: "application/json" } })
      if (leg1.status !== 402) throw new Error(`expected a 402 quote, got ${leg1.status}`)
      const quote = await leg1.json()
      const accept = quote.accepts[0]

      this.setState("wallet",
        `Sign in wallet: ${this.formatAmount(accept)} → ${accept.payTo} (network fee paid by facilitator)`)
      const signed = await fetch(`${this.walletUrlValue}/sign`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ paymentRequired: quote }),
      })
      if (!signed.ok) throw new Error(`wallet refused: ${(await signed.json()).error || signed.status}`)
      const { headers } = await signed.json()

      this.setState("settling", "Submitting to Hedera…")
      const leg2 = await fetch(url, { headers: { accept: "application/json", ...headers } })
      const body = await leg2.json()
      if (leg2.status !== 200) throw new Error(body.error || `settlement failed (${leg2.status})`)

      this.success(body)
    } catch (error) {
      this.setState("failed", error.message)
    }
  }

  setState(state, message) {
    this.element.dataset.checkoutState = state
    this.buttonTarget.disabled = state !== "failed"
    if (state === "failed") this.buttonTarget.textContent = "Try again"
    const badge = { quoting: "badge-pending", wallet: "badge-pending", settling: "badge-pending", failed: "badge-bad" }[state]
    this.statusTarget.innerHTML = `<span class="badge ${badge}">${state}</span> <span class="t-small">${this.escape(message)}</span>`
    this.statusTarget.focus()
  }

  success(body) {
    this.element.dataset.checkoutState = "success"
    const txId = body.transaction_id
    this.receiptTarget.innerHTML = `
      <div class="badge badge-ok">✓ licensed</div>
      <h3 style="margin-top: var(--s-2)">Licensed — unit #${body.license.serial}</h3>
      <a class="btn btn-primary" href="${body.files[0]?.url}" download>Download files</a>
      <dl class="t-small" style="margin-bottom:0">
        <dt class="muted">transaction</dt>
        <dd style="margin:0 0 var(--s-2)"><a class="mono" href="${body.hashscan_url}" target="_blank" rel="noopener">${this.escape(txId)}</a></dd>
        <dt class="muted">certificate</dt>
        <dd style="margin:0"><a class="mono" href="${body.verify_url}">${this.escape(body.license.cert_id)}</a></dd>
      </dl>`
    this.receiptTarget.hidden = false
    this.statusTarget.innerHTML = ""
    this.buttonTarget.hidden = true
    this.offerTargets.forEach((o) => (o.hidden = true))
    this.receiptTarget.focus()
  }

  formatAmount(accept) {
    return accept.asset === "0.0.0"
      ? `${(Number(accept.amount) / 1e8).toFixed(2)} HBAR`
      : `${(Number(accept.amount) / 1e6).toFixed(2)} USDC`
  }

  escape(text) {
    const div = document.createElement("div")
    div.textContent = String(text)
    return div.innerHTML
  }
}
