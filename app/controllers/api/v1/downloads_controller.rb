# The x402 paywall: GET /api/v1/models/:model_id/download?license=<kind>
# Implements plan legs 1-4 and the full error table. Facilitator timeouts
# NEVER fail a purchase — the tx may have settled; we reconcile via mirror.
class Api::V1::DownloadsController < Api::V1::BaseController
  # Every purchase costs two requests here — the 402 probe and the signed retry
  # — so 30/min meant an agent working sequentially through a shopping list
  # stalled at 15 models, which is a normal size for one. The unpaid probe is
  # the only free work (a handful of queries and a JSON render); the paid leg is
  # gated by the facilitator, not by us. Set well above any sequential agent
  # run, low enough that an anonymous flood of probes cannot occupy the app.
  RATE_LIMIT = 120
  rate_limit to: RATE_LIMIT, within: 1.minute, store: RateLimitStore, with: :api_rate_limited
  after_action :record_payment_request

  def show
    model = Model3d.find(params[:model_id])
    raise ActiveRecord::RecordNotFound if model.draft?
    sandbox = sandbox_request?
    response.set_header("X-Printwright-Sandbox", "true") if sandbox
    raw_payment = X402::PaymentHeader.raw(request)
    payload = X402::PaymentHeader.decode(request) if raw_payment
    if payload && (existing = Purchase.find_by(replay_key: replay_key(payload)))
      requested_kind = params.fetch(:license, "personal")
      unless existing.license_offer.model3d_id == model.id && existing.license_offer.kind == requested_kind
        return render json: { error: "duplicate_payment", status: existing.status }, status: :conflict
      end
      return replay(payload)
    end
    return render_listing_unavailable(model) unless model.published?

    offer = model.license_offers.find_by!(kind: params.fetch(:license, "personal"))
    requirements = requirements_for(offer, sandbox: sandbox)
    if payload.nil?
      return render json: { error: "sold_out" }, status: :gone if !sandbox && offer.sold_out?
      @analytics_event = {
        model_ids: [ model.id ], event: "payment_request",
        channel: analytics_channel, source: "checkout"
      } unless sandbox
      return payment_required(requirements)
    end

    matched = requirements.match(payload["accepted"])
    return payment_required(requirements, error: "invalid_payment_requirements") unless matched

    authorize_chat_purchase!(offer, payload, matched) if request.headers[Chat::PurchaseIntent::HEADER].present?

    # Replay detection must precede the sold-out gate: an already-paid
    # purchase keeps its recovery path even when the offer sells out.
    purchase = create_purchase(offer, payload, matched, sandbox: sandbox)
    return replay(payload) if purchase.nil? # lost a same-tx race
    return render json: { error: "sold_out" }, status: :gone if purchase == :sold_out
    return render_listing_unavailable(offer.model3d.reload) if purchase == :listing_unavailable
    if purchase == :offer_changed
      current = offer.model3d.license_offers.find_by!(kind: offer.kind)
      return payment_required(requirements_for(current, sandbox: sandbox), error: "offer_changed")
    end

    verify_and_settle(purchase, payload, matched)
  rescue ActiveRecord::RecordNotFound
    render json: { error: "not_found" }, status: :not_found
  rescue X402::PaymentHeader::InvalidPayload
    render json: { error: "invalid_payload" }, status: :bad_request
  rescue Chat::PurchaseIntent::Invalid => e
    render json: { error: e.code }, status: :forbidden
  end

  private

  def record_payment_request
    Analytics::Recorder.record_later(**@analytics_event) if response.status == 402 && @analytics_event
  end

  def analytics_channel
    request.headers["X-Printwright-Channel"] == "human" ? "human" : "agent"
  end

  def payment_required(requirements, error: "payment required")
    body = requirements.payment_required(error: error)
    response.set_header("PAYMENT-REQUIRED", Base64.strict_encode64(JSON.generate(body)))
    response.set_header("WWW-Authenticate", "x402")
    render json: body, status: :payment_required
  end

  def requirements_for(offer, sandbox:)
    klass = sandbox ? Sandbox::Requirements : X402::Requirements
    klass.new(offer: offer, resource_url: request.original_url)
  end

  def replay_key(payload)
    Digest::SHA256.hexdigest(payload.dig("payload", "transaction"))
  end

  # Capacity is decided HERE, inside the offer row lock, before any money
  # moves — so two in-flight payments can't both reserve the last unit; a
  # sold-out offer refuses before payment is ever accepted (A5/E6).
  # License.allocate! keeps its own max_units enforcement as the backstop.
  def create_purchase(offer, payload, matched, sandbox:)
    offer.with_lock do
      if !offer.active?
        :offer_changed
      elsif !offer.model3d.reload.published?
        :listing_unavailable
      elsif !sandbox && offer.sold_out?
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
      return undeliverable(purchase, purchase.license) unless deliverable?(purchase)

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
    return undeliverable(purchase, license) unless deliverable?(purchase)

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
    # Defensive backstop only: reservation already counted this purchase
    # against the cap before payment, so allocation cannot legitimately hit
    # it. Record honestly and surface the tx id for operator review.
    purchase.update!(error_reason: "capacity_overrun")
    render json: { error: "sold_out", transaction_id: purchase.payment_tx_id }, status: :gone
  end

  # The file is the sale. A model whose parts are all missing or detached cannot
  # be delivered, and money has already moved — we never refund — so this can
  # never be dressed up as a 200 with an empty `files` array.
  def deliverable?(purchase)
    purchase.sandbox? || purchase.model3d.deliverable_files.any?
  end

  # Stay in `settled`: the replay path retries delivery from there, so the same
  # signed payment claims the file once an operator reattaches it. Hand back the
  # durable handles with the failure so the buyer's recovery does not depend on
  # them having kept this response.
  def undeliverable(purchase, license)
    purchase.update!(error_reason: "no_deliverable_file")
    Rails.logger.error(
      "delivery_failed purchase=#{purchase.id} license=#{license.cert_id} " \
      "model=#{purchase.model3d.id} tx=#{purchase.payment_tx_id} reason=no_deliverable_file"
    )
    render json: {
      error: "no_deliverable_file",
      message: "Payment settled, but this model has no downloadable file right now. " \
               "Your license is issued and the file is owed to you: retry this exact signed " \
               "payment, or fetch it later from the receipt below.",
      recoverable: true,
      retry_after: 60,
      cert_id: license.cert_id,
      transaction_id: purchase.payment_tx_id,
      receipt: receipt_capability(license),
      verify_url: "#{request.base_url}/verify/#{license.verify_slug}"
    }, status: :service_unavailable
  end

  def delivery_payload(purchase)
    license = purchase.license
    return sandbox_delivery_payload(purchase, license) if purchase.sandbox?

    # Build the certificate now (not in the async CertMintJob) so the delivered
    # proof bundle is complete and independently verifiable the instant the
    # agent receives it; CertMintJob then just anchors the commitment.
    license.update!(cert_json: Certificates::Builder.call(license)) if license.cert_json.blank?
    grant = DownloadGrant.for(license)
    model = purchase.model3d
    {
      files: model.deliverable_files.map do |index, file|
        { kind: file.kind, url: api_v1_file_url(grant.token, f: index), expires_at: grant.expires_at.iso8601 }
      end,
      license: license_summary(license),
      certificate: license.cert_json.presence,
      # Portable, self-contained proof the agent can verify against Hedera even
      # if Printwright is unreachable; re-fetch bundle_url once anchored to pick
      # up the consensus coordinates (delivery precedes the async HCS anchor).
      proof_bundle: Certificates::Bundle.for(license),
      bundle_url: api_v1_certificate_url(license.cert_id),
      verify_url: "#{request.base_url}/verify/#{license.verify_slug}",
      # The certificate as a keepable document, rendered server-side so an agent
      # never needs a browser. Not part of the proof bundle: PWC-1 is frozen and
      # closed, and the PDF proves nothing the bundle does not already carry.
      certificate_pdf_url: verify_certificate_pdf_url(license.verify_slug),
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
      transaction_url: Hedera::Network.transaction_url(purchase.payment_tx_id)
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
      proof_bundle: Certificates::Bundle.for(license),
      bundle_url: api_v1_certificate_url(license.cert_id),
      verify_url: "#{request.base_url}/verify/#{license.verify_slug}",
      # Rendered too, and it says SANDBOX REHEARSAL on its face — a rehearsal
      # must exercise the same shape the paid flow returns.
      certificate_pdf_url: verify_certificate_pdf_url(license.verify_slug),
      transaction_id: purchase.payment_tx_id,
      transaction_url: nil,
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

  # THE durable delivery path, not a footnote. The `files` URLs above ride a
  # download grant that eventually lapses; this token does not expire and needs
  # no account, so it is how a buyer or their agent gets the same files back
  # next month. Both URLs take `?token=`: `url` is the human receipt page,
  # `files_url` the same thing as JSON for an agent.
  def receipt_capability(license)
    {
      url: purchase_receipt_url(license.cert_id),
      files_url: purchase_receipt_url(license.cert_id, format: :json),
      download_url: purchase_receipt_download_url(license.cert_id),
      package_url: purchase_receipt_package_url(license.cert_id),
      token: license.signed_id(purpose: "purchase-receipt"),
      expires_at: nil,
      note: "Durable: append ?token=<token> to re-download this license's files at any time, " \
            "with no account. Pass ?f=<index> to download_url for a specific part."
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
