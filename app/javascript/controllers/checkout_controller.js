import { Controller } from "@hotwired/stimulus"

// Human copy + retry affordance for each API error code (plan 06 error table,
// api/v1/downloads_controller.rb). Codes not listed here (e.g. a facilitator
// invalidReason like "invalid_signature") fall back to a generic message and
// are treated as retryable — a fresh quote + signature is a real fix for those.
const FAILURE_COPY = {
  sold_out: () => "This offer is sold out — there are no license slots left.",
  facilitator_unavailable: (retryAfter) =>
    `The payment processor is temporarily unavailable. Try again in about ${retryAfter || 5} seconds.`,
  rate_limited: (retryAfter) =>
    `Too many purchase attempts right now. Wait about ${retryAfter || 60} seconds, then try again.`,
  duplicate_payment: () =>
    "This payment was already submitted and is being handled — retrying here won't help.",
  invalid_payload: () =>
    "The payment could not be read by the server. Retrying this exact request won't help.",
  wallet_refused: () => "You declined the payment request in your wallet.",
  purchases_disabled: () => "Chat purchases are currently disabled.",
  spend_cap_exceeded: () => "This proposal exceeds the configured conversation spend cap.",
  daily_spend_cap_exceeded: () => "The chat purchase budget for today has been reached.",
  approval_expired: () => "This approval expired. Ask the shopkeeper for a fresh proposal.",
  stale_proposal: () => "The offer changed. Ask the shopkeeper for a fresh proposal before paying.",
  approval_already_used: () => "This approval has already been used.",
  invalid_purchase_intent: () => "The server could not verify this purchase approval.",
  payment_intent_replayed: () => "This approval is already bound to a different signed payment.",
}

// These are terminal for the purchase attempt: no retry button. Everything
// else (facilitator_unavailable, rate_limited, wallet_refused, and unmapped
// codes) keeps the "Try again" affordance.
const TERMINAL_ERRORS = new Set([
  "sold_out", "duplicate_payment", "invalid_payload", "purchases_disabled", "spend_cap_exceeded",
  "daily_spend_cap_exceeded", "approval_expired", "stale_proposal", "approval_already_used",
  "invalid_purchase_intent", "payment_intent_replayed",
])
const TERMINAL_LABELS = { sold_out: "Sold out", duplicate_payment: "Already submitted", invalid_payload: "Unavailable" }

// S3 checkout state machine (plan 06): idle -> quoting -> wallet -> settling
// -> success | failed. The signer is a local demo-wallet daemon; the states,
// copy and receipt are exactly what a HashPack-backed signer would use.
export default class extends Controller {
  static targets = ["offer", "button", "status", "receipt"]
  static values = {
    downloadUrl: String,
    walletUrl: { type: String, default: "http://localhost:4022" },
    approvalUrl: String,
    buttonPrefix: { type: String, default: "Buy license" },
  }

  connect() {
    this.updatePrice()
  }

  updatePrice() {
    const offer = this.selectedOffer()
    if (!this.hasButtonTarget || !offer) return
    // A failure belongs to the offer that produced it. Picking a different one
    // clears it — otherwise a terminal state (sold out, already submitted)
    // leaves the button disabled for an offer that is still buyable. In-flight
    // states are left alone: their disabled button is not stale.
    if (this.element.dataset.checkoutState === "failed") {
      this.element.dataset.checkoutState = ""
      this.buttonTarget.disabled = false
      this.statusTarget.innerHTML = ""
    }
    // Prefer the server-rendered price: HBAR-lead offers show "ℏ · $" at the
    // live rate, which a client-side cents-to-dollars format would discard.
    const display = offer.dataset.priceDisplay || `$${(offer.dataset.priceCents / 100).toFixed(2)}`
    this.buttonTarget.textContent = `${this.buttonPrefixValue} · ${display}`
  }

  selectedOffer() {
    return this.offerTargets.find((o) => o.querySelector("input").checked) || this.offerTargets[0]
  }

  async buy() {
    try {
      // A timeout after signing may mean the same transaction settled. Never
      // ask for a second signature in that state; retry the identical bytes so
      // Door 1 can reconcile by transaction digest.
      if (this.pendingPayment) return await this.submitPendingPayment()

      const kind = this.selectedOffer().querySelector("input").value
      let url = `${this.downloadUrlValue}?license=${kind}`
      let quote
      let purchaseIntent
      if (this.hasApprovalUrlValue) {
        this.setState("quoting", "Checking the proposal and reserving its spend cap…")
        const approval = await fetch(this.approvalUrlValue, {
          method: "POST",
          headers: { accept: "application/json", "x-csrf-token": this.csrfToken() },
        })
        const body = await approval.json().catch(() => ({}))
        if (!approval.ok) {
          return this.fail(body.error, body.error || `approval failed (${approval.status})`, body.retry_after)
        }

        quote = body.payment_required
        url = body.purchase_url
        purchaseIntent = body.purchase_intent
      } else {
        this.setState("quoting", "Fetching payment terms…")
        const leg1 = await fetch(url, { headers: { accept: "application/json" } })
        if (leg1.status !== 402) {
          const body = await leg1.json().catch(() => ({}))
          return this.fail(body.error, `expected a 402 quote, got ${leg1.status}`, body.retry_after)
        }
        quote = await leg1.json()
      }
      const accept = quote.accepts[0]

      this.setState("wallet",
        `Sign in wallet: ${this.formatAmount(accept)} → ${accept.payTo} (network fee paid by facilitator)`)
      const signed = await fetch(`${this.walletUrlValue}/sign`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ paymentRequired: quote }),
      })
      if (!signed.ok) {
        const body = await signed.json().catch(() => ({}))
        return this.fail("wallet_refused", `wallet refused: ${body.error || signed.status}`)
      }
      const { headers } = await signed.json()

      const paymentHeaders = { accept: "application/json", ...headers }
      if (purchaseIntent) paymentHeaders["X-Printwright-Purchase-Intent"] = purchaseIntent
      this.pendingPayment = { url, headers: paymentHeaders }
      await this.submitPendingPayment()
    } catch (error) {
      this.fail(null, error.message)
    }
  }

  async submitPendingPayment() {
    const { url, headers } = this.pendingPayment
    this.setState("settling", "Submitting to Hedera…")
    const leg2 = await fetch(url, { headers })
    const body = await leg2.json()
    if (leg2.status !== 200) {
      // These failures can be recovered only by replaying this same signed
      // transaction. Other failures need a fresh attempt/proposal.
      if (!["facilitator_unavailable", "rate_limited"].includes(body.error)) this.pendingPayment = null
      return this.fail(body.error, body.error || `settlement failed (${leg2.status})`, body.retry_after)
    }

    this.pendingPayment = null
    this.success(body)
  }

  setState(state, message) {
    this.element.dataset.checkoutState = state
    this.buttonTarget.disabled = true
    const badge = { quoting: "badge-pending", wallet: "badge-pending", settling: "badge-pending" }[state]
    this.statusTarget.innerHTML = `<span class="badge ${badge}">${state}</span> <span class="t-small">${this.escape(message)}</span>`
    this.statusTarget.focus()
  }

  // A purchase attempt didn't complete. `code` is the server error string
  // (or a client-side reason like "wallet_refused"); terminal codes get a
  // disabled button instead of a retry invite. `detail` is the raw technical
  // string, kept visible but secondary for operators/judges.
  fail(code, detail, retryAfter) {
    const terminal = TERMINAL_ERRORS.has(code)
    this.element.dataset.checkoutState = "failed"
    this.buttonTarget.disabled = terminal
    this.buttonTarget.textContent = terminal ? (TERMINAL_LABELS[code] || "Unavailable") : "Try again"
    const message = (FAILURE_COPY[code] && FAILURE_COPY[code](retryAfter)) || "The payment could not be completed."
    this.statusTarget.innerHTML = `<span class="badge badge-bad">failed</span> <span class="t-small">${this.escape(message)}</span>` +
      (detail ? `<span class="t-caption muted" style="display:block">${this.escape(detail)}</span>` : "")
    this.statusTarget.focus()
  }

  success(body) {
    this.element.dataset.checkoutState = "success"
    const txId = body.transaction_id
    const maxUnits = body.license.max_units
    const serialLabel = maxUnits ? `#${body.license.serial} of ${maxUnits}` : `#${body.license.serial}`
    const capNote = maxUnits
      ? `<p class="t-caption muted">${body.license.remaining_units} of ${maxUnits} license slots now remain. This cap does not technically restrict physical printing.</p>`
      : ""
    const shareCard = body.share_card_url
      ? `<a href="${this.escape(body.share_card_url)}" target="_blank" rel="noopener">
          <img src="${this.escape(body.share_card_url)}" alt="Share card for ${this.escape(body.license.cert_id)}" style="display:block; margin:var(--s-2) 0; max-width:100%; height:auto">
        </a>`
      : ""
    const receiptLink = body.receipt
      ? `<a class="btn" href="${this.escape(body.receipt.url)}?token=${encodeURIComponent(body.receipt.token)}">Open durable receipt</a>`
      : ""
    this.receiptTarget.innerHTML = `
      <div class="badge badge-ok">✓ licensed</div>
      <h3 style="margin-top: var(--s-2)">Licensed — unit ${serialLabel}</h3>
      ${capNote}
      <a class="btn btn-primary" href="${body.files[0]?.url}" download>Download files</a>
      ${receiptLink}
      <dl class="t-small" style="margin-bottom:0">
        <dt class="muted">transaction</dt>
        <dd style="margin:0 0 var(--s-2)"><a class="mono" href="${body.hashscan_url}" target="_blank" rel="noopener">${this.escape(txId)}</a></dd>
        <dt class="muted">certificate</dt>
        <dd style="margin:0"><a class="mono" href="${body.verify_url}">${this.escape(body.license.cert_id)}</a></dd>
      </dl>
      ${shareCard}`
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

  csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }
}
