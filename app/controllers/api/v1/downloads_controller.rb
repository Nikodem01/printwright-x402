# The x402 paywall: GET /api/v1/models/:model_id/download?license=<kind>
# Implements plan legs 1-4 and the full error table. Facilitator timeouts
# NEVER fail a purchase — the tx may have settled; we reconcile via mirror.
class Api::V1::DownloadsController < Api::V1::BaseController
  rate_limit to: 30, within: 1.minute, store: RateLimitStore, with: :api_rate_limited

  def show
    model = Model3d.published.find(params[:model_id])
    offer = model.license_offers.find_by!(kind: params.fetch(:license, "personal"))

    sandbox = sandbox_request?
    response.set_header("X-Printwright-Sandbox", "true") if sandbox
    requirements = if sandbox
      Sandbox::Requirements.new(offer: offer, resource_url: request.original_url)
    else
      X402::Requirements.new(offer: offer, resource_url: request.original_url)
    end
    if X402::PaymentHeader.raw(request).nil?
      return render json: { error: "sold_out" }, status: :gone if !sandbox && offer.sold_out?
      return payment_required(requirements)
    end

    payload = X402::PaymentHeader.decode(request)
    matched = requirements.match(payload["accepted"])
    return payment_required(requirements, error: "invalid_payment_requirements") unless matched

    authorize_chat_purchase!(offer, payload, matched) if request.headers[Chat::PurchaseIntent::HEADER].present?

    # Replay detection must precede the sold-out gate: an already-paid
    # purchase keeps its recovery path even when the offer sells out.
    return replay(payload) if Purchase.exists?(replay_key: replay_key(payload))

    purchase = create_purchase(offer, payload, matched, sandbox: sandbox)
    return replay(payload) if purchase.nil? # lost a same-tx race
    return render json: { error: "sold_out" }, status: :gone if purchase == :sold_out

    verify_and_settle(purchase, payload, matched)
  rescue ActiveRecord::RecordNotFound
    render json: { error: "not_found" }, status: :not_found
  rescue X402::PaymentHeader::InvalidPayload
    render json: { error: "invalid_payload" }, status: :bad_request
  rescue Chat::PurchaseIntent::Invalid => e
    render json: { error: e.code }, status: :forbidden
  end

  private

  def payment_required(requirements, error: "payment required")
    body = requirements.payment_required(error: error)
    response.set_header("PAYMENT-REQUIRED", Base64.strict_encode64(JSON.generate(body)))
    response.set_header("WWW-Authenticate", "x402")
    render json: body, status: :payment_required
  end

  def replay_key(payload)
    Digest::SHA256.hexdigest(payload.dig("payload", "transaction"))
  end

  # Capacity is decided HERE, inside the offer row lock, before any money
  # moves — so two in-flight payments can't both reserve the last unit and
  # leave one buyer in the refundless sold-out-after-payment path (A5/E6).
  # License.allocate! keeps its own max_units enforcement as the backstop.
  def create_purchase(offer, payload, matched, sandbox:)
    offer.with_lock do
      if !sandbox && offer.sold_out?
        :sold_out
      else
        Purchase.create!(
          license_offer: offer,
          asset: matched[:asset],
          amount_base_units: matched[:amount],
          replay_key: replay_key(payload),
          requirements_json: matched.deep_stringify_keys,
          sandbox: sandbox
        )
      end
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    nil
  end

  # Same signed transaction presented again. Retryable states move forward
  # (the 503 path told the client to retry this exact payment); true
  # duplicates and dead purchases get 409.
  def replay(payload)
    purchase = Purchase.find_by!(replay_key: replay_key(payload))
    if purchase.purchase_batch
      return render json: { error: "duplicate_payment", status: purchase.purchase_batch.status }, status: :conflict
    end
    case purchase.status
    when "delivered"
      complete_chat_purchase_intent!
      render json: delivery_payload(purchase), status: :conflict
    when "settled" # paid but delivery previously crashed — finish the job
      deliver(purchase, {
        "transaction" => purchase.payment_tx_id,
        "network" => purchase.sandbox? ? Sandbox::Requirements::NETWORK : X402::Requirements.network,
        "sandbox" => purchase.sandbox?
      })
    when "verified"
      reconcile(purchase, payload)
    when "pending"
      if purchase.error_reason == "facilitator_unavailable"
        verify_and_settle(purchase, payload, purchase.requirements_json)
      else
        render json: { error: "duplicate_payment", status: purchase.status }, status: :conflict
      end
    else
      render json: { error: "duplicate_payment", status: purchase.status }, status: :conflict
    end
  end

  # Settle previously timed out: check the mirror node before retrying.
  def reconcile(purchase, payload)
    return settle(purchase, payload, purchase.requirements_json) if purchase.sandbox?

    if (tx_id = X402::MirrorReconciler.call(purchase))
      purchase.update!(payment_tx_id: tx_id)
      purchase.transition_to!(:settled)
      deliver(purchase, { "transaction" => tx_id, "network" => X402::Requirements.network })
    else
      settle(purchase, payload, purchase.requirements_json)
    end
  end

  def verify_and_settle(purchase, payload, matched)
    verification = facilitator_for(purchase).verify(payload, matched)
    unless verification["isValid"]
      purchase.update!(error_reason: verification["invalidReason"])
      purchase.transition_to!(:failed_verification)
      return render json: { error: verification["invalidReason"] }, status: :payment_required
    end
    purchase.update!(buyer_hint: verification["payer"] || "bearer")
    purchase.transition_to!(:verified)

    settle(purchase, payload, matched)
  rescue FacilitatorClient::Unavailable
    facilitator_unavailable(purchase)
  end

  def settle(purchase, payload, matched)
    settlement = facilitator_for(purchase).settle(payload, matched)
    unless settlement["success"]
      purchase.update!(error_reason: settlement["errorReason"])
      purchase.transition_to!(:failed_settlement)
      return render json: { error: settlement["errorReason"] }, status: :payment_required
    end
    # Hedera scheme spec says transactionId, core v2 says transaction — accept either.
    purchase.update!(payment_tx_id: settlement["transaction"] || settlement["transactionId"])
    purchase.transition_to!(:settled)
    deliver(purchase, settlement)
  rescue FacilitatorClient::Unavailable
    facilitator_unavailable(purchase)
  end

  # Money moved but our facilitator call failed/timed out: keep the purchase
  # alive (pending/verified), tell the client to retry; reconcile on replay.
  def facilitator_unavailable(purchase)
    purchase.update!(error_reason: "facilitator_unavailable")
    render json: { error: "facilitator_unavailable", retry_after: 5 }, status: :service_unavailable
  end

  def deliver(purchase, settlement)
    license = purchase.license || License.allocate!(purchase)
    Sandbox::Topic.anchor!(license) if purchase.sandbox? && !license.anchored?
    purchase.transition_to!(:delivered)
    CertMintJob.perform_later(license.id) unless purchase.sandbox?
    WebhookFanoutJob.perform_later(license.id, "sale.completed") unless purchase.sandbox?
    unless purchase.sandbox?
      DesignerPayoutJob.perform_later(purchase_ids: [ purchase.id ], ref: "purchase-#{purchase.id}")
    end
    complete_chat_purchase_intent!
    response.set_header("PAYMENT-RESPONSE", Base64.strict_encode64(JSON.generate(settlement)))
    response.set_header("X-PAYMENT-RESPONSE", response.get_header("PAYMENT-RESPONSE"))
    render json: delivery_payload(purchase), status: :ok
  rescue License::SoldOut
    # Money moved but the last unit went to a concurrent buyer. No refund
    # rail in MVP: record it honestly and surface the tx id for support.
    purchase.update!(error_reason: "sold_out_after_payment")
    render json: { error: "sold_out", transaction_id: purchase.payment_tx_id }, status: :gone
  end

  def delivery_payload(purchase)
    license = purchase.license
    return sandbox_delivery_payload(purchase, license) if purchase.sandbox?

    grant = license.download_grants.detect(&:usable?) || DownloadGrant.issue!(license)
    model = purchase.model3d
    {
      files: model.printable_files.map do |f|
        { kind: f.kind, url: api_v1_file_url(grant.token), expires_at: grant.expires_at.iso8601 }
      end,
      license: license_summary(license),
      certificate: license.cert_json.presence,
      verify_url: "#{request.base_url}/verify/#{license.verify_slug}",
      share_card_url: verify_share_card_url(license.verify_slug),
      receipt: receipt_capability(license),
      print_feedback: {
        url: api_v1_license_print_reports_url(license.cert_id),
        receipt_token: license.signed_id(purpose: "print-feedback")
      },
      model_updates: {
        url: api_v1_license_latest_version_url(license.cert_id),
        download_url: api_v1_license_latest_version_file_url(license.cert_id),
        receipt_token: license.signed_id(purpose: "model-updates")
      },
      transaction_id: purchase.payment_tx_id,
      hashscan_url: "#{Hedera::Network.hashscan_base}/transaction/#{purchase.payment_tx_id}"
    }
  end

  def sandbox_delivery_payload(purchase, license)
    {
      sandbox: true,
      warning: Sandbox::Requirements::WARNING,
      files: [ {
        kind: "sandbox_receipt",
        url: api_v1_sandbox_file_url(license.cert_id),
        expires_at: nil,
        sandbox: true
      } ],
      license: { cert_id: license.cert_id, serial: license.serial, kind: purchase.license_offer.kind },
      certificate: license.cert_json,
      verify_url: "#{request.base_url}/verify/#{license.verify_slug}",
      transaction_id: purchase.payment_tx_id,
      hashscan_url: nil,
      sandbox_url: api_v1_sandbox_transaction_url(purchase.payment_tx_id)
    }
  end

  def license_summary(license)
    offer = license.purchase.license_offer
    {
      cert_id: license.cert_id,
      serial: license.serial,
      kind: offer.kind,
      max_units: offer.max_units,
      remaining_units: offer.units_remaining
    }
  end

  def receipt_capability(license)
    {
      url: purchase_receipt_url(license.cert_id),
      token: license.signed_id(purpose: "purchase-receipt")
    }
  end

  def facilitator_for(purchase)
    purchase.sandbox? ? Sandbox::Facilitator.new : FacilitatorClient.new
  end

  def sandbox_request?
    request.headers["X-Sandbox"] == "true"
  end

  def authorize_chat_purchase!(offer, payload, matched)
    @chat_purchase_context = Chat::PurchaseIntent.authorize!(
      token: request.headers[Chat::PurchaseIntent::HEADER],
      offer: offer,
      request_path: request.fullpath,
      payload: payload,
      matched: matched
    )
  end

  def complete_chat_purchase_intent!
    Chat::PurchaseIntent.complete!(@chat_purchase_context) if @chat_purchase_context
  end
end
