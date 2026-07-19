class Api::V1::BatchesController < Api::V1::BaseController
  InvalidBatch = Class.new(StandardError)
  MAX_ITEMS = 20

  rate_limit to: 15, within: 1.minute, store: RateLimitStore, with: :api_rate_limited

  def create
    items = normalized_items
    webhook = normalized_webhook
    offers = items.map { |item| offer_for(item) }
    sandbox = request.headers["X-Sandbox"] == "true"
    response.set_header("X-Printwright-Sandbox", "true") if sandbox
    requirements = X402::BatchRequirements.new(
      offers: offers, resource_url: request.original_url, sandbox: sandbox
    )

    if X402::PaymentHeader.raw(request).nil?
      return render json: { error: "sold_out" }, status: :gone if !sandbox && sold_out?(offers)
      return payment_required(requirements)
    end

    payload = X402::PaymentHeader.decode(request)
    matched = requirements.match(payload["accepted"])
    return payment_required(requirements, error: "invalid_payment_requirements") unless matched

    key = replay_key(payload)
    return replay_existing(key, payload) if Purchase.exists?(replay_key: key)

    batch = reserve(offers, matched, key, sandbox: sandbox, webhook: webhook)
    return replay_existing(key, payload) if batch.nil?
    return render json: { error: "sold_out" }, status: :gone if batch == :sold_out

    verify_and_settle(batch, payload)
  rescue X402::BatchRequirements::IncompatiblePayees
    render json: { error: "incompatible_payees" }, status: :unprocessable_entity
  rescue Webhooks::Target::Invalid => error
    render json: { error: "invalid_webhook", message: error.message }, status: :unprocessable_entity
  rescue InvalidBatch, ActionController::ParameterMissing
    render json: { error: "invalid_batch" }, status: :bad_request
  rescue X402::PaymentHeader::InvalidPayload
    render json: { error: "invalid_payload" }, status: :bad_request
  end

  private

  def normalized_items
    raw = params.require(:items)
    raise InvalidBatch unless raw.is_a?(Array) && raw.length.between?(1, MAX_ITEMS)

    raw.map do |item|
      item = item.permit(:model_id, :license)
      model_id = item[:model_id].to_s
      kind = item[:license].presence || "personal"
      raise InvalidBatch unless model_id.match?(/\A[1-9]\d*\z/) && LicenseOffer::KINDS.include?(kind)

      { model_id: model_id.to_i, license: kind }
    end
  end

  def offer_for(item)
    Model3d.published.find(item[:model_id]).license_offers.find_by!(kind: item[:license])
  end

  def normalized_webhook
    return nil if params[:webhook].blank?

    webhook = params.require(:webhook).permit(:url, :secret)
    Webhooks::Target.validate!(url: webhook[:url], secret: webhook[:secret])
    { url: webhook[:url], secret: webhook[:secret] }
  end

  def payment_required(requirements, error: "payment required")
    body = requirements.payment_required(error: error)
    response.set_header("PAYMENT-REQUIRED", Base64.strict_encode64(JSON.generate(body)))
    response.set_header("WWW-Authenticate", "x402")
    render json: body, status: :payment_required
  end

  def sold_out?(offers)
    offers.tally.any? do |offer, requested|
      offer.max_units && offer.purchases.where(sandbox: false)
        .where.not(status: LicenseOffer::FAILED_STATUSES).count + requested > offer.max_units
    end
  end

  def replay_key(payload)
    Digest::SHA256.hexdigest(payload.dig("payload", "transaction"))
  end

  def reserve(offers, matched, key, sandbox:, webhook:)
    PurchaseBatch.transaction do
      locked = LicenseOffer.where(id: offers.map(&:id).uniq).order(:id).lock.index_by(&:id)
      resolved = offers.map { |offer| locked.fetch(offer.id) }
      return :sold_out if !sandbox && sold_out?(resolved)

      batch = PurchaseBatch.create!(
        replay_key: key, asset: matched.requirement[:asset],
        amount_base_units: matched.requirement[:amount],
        requirements_json: matched.requirement.deep_stringify_keys,
        sandbox: sandbox,
        webhook_url: webhook&.fetch(:url, nil),
        webhook_secret_ciphertext: webhook && Webhooks::SecretBox.encrypt(webhook.fetch(:secret))
      )
      resolved.each_with_index do |offer, position|
        child_requirement = matched.requirement.merge(amount: matched.item_amounts.fetch(position))
        batch.purchases.create!(
          license_offer: offer, batch_position: position,
          asset: matched.requirement[:asset], amount_base_units: matched.item_amounts.fetch(position),
          replay_key: position.zero? ? key : Digest::SHA256.hexdigest("#{key}:#{position}"),
          requirements_json: child_requirement.deep_stringify_keys,
          sandbox: sandbox
        )
      end
      batch
    end
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  def verify_and_settle(batch, payload)
    verification = facilitator_for(batch).verify(payload, batch.requirements_json)
    unless verification["isValid"]
      fail_batch(batch, "failed_verification", verification["invalidReason"])
      return render json: { error: verification["invalidReason"] }, status: :payment_required
    end

    buyer = verification["payer"] || "bearer"
    PurchaseBatch.transaction do
      batch.update!(status: "verified", buyer_hint: buyer)
      batch.purchases.each do |purchase|
        purchase.update!(buyer_hint: buyer)
        purchase.transition_to!(:verified)
      end
    end
    settle(batch, payload)
  rescue FacilitatorClient::Unavailable
    facilitator_unavailable(batch)
  end

  def settle(batch, payload)
    settlement = facilitator_for(batch).settle(payload, batch.requirements_json)
    unless settlement["success"]
      fail_batch(batch, "failed_settlement", settlement["errorReason"])
      return render json: { error: settlement["errorReason"] }, status: :payment_required
    end

    settle_success(batch, settlement["transaction"] || settlement["transactionId"])
    deliver(batch, settlement)
  rescue FacilitatorClient::Unavailable
    facilitator_unavailable(batch)
  end

  def settle_success(batch, transaction_id)
    PurchaseBatch.transaction do
      batch.update!(status: "settled", payment_tx_id: transaction_id)
      batch.purchases.each do |purchase|
        purchase.update!(payment_tx_id: transaction_id)
        purchase.transition_to!(:settled)
      end
    end
  end

  def fail_batch(batch, status, reason)
    PurchaseBatch.transaction do
      batch.update!(status: status, error_reason: reason)
      batch.purchases.each do |purchase|
        purchase.update!(error_reason: reason)
        purchase.transition_to!(status)
      end
    end
  end

  def facilitator_unavailable(batch)
    batch.update!(error_reason: "facilitator_unavailable")
    render json: { error: "facilitator_unavailable", retry_after: 5 }, status: :service_unavailable
  end

  def replay(batch, payload)
    case batch.status
    when "delivered"
      render json: delivery_payload(batch), status: :conflict
    when "settled"
      deliver(batch, { "transaction" => batch.payment_tx_id, "network" => network_for(batch) })
    when "verified"
      reconcile(batch, payload)
    when "pending"
      if batch.error_reason == "facilitator_unavailable"
        verify_and_settle(batch, payload)
      else
        render json: { error: "duplicate_payment", status: batch.status }, status: :conflict
      end
    else
      render json: { error: "duplicate_payment", status: batch.status }, status: :conflict
    end
  end

  def replay_existing(key, payload)
    existing = Purchase.find_by!(replay_key: key)
    return replay(existing.purchase_batch, payload) if existing.purchase_batch

    render json: { error: "duplicate_payment", status: existing.status }, status: :conflict
  end

  def reconcile(batch, payload)
    return settle(batch, payload) if batch.sandbox?

    if (transaction_id = X402::MirrorReconciler.call(batch))
      settle_success(batch, transaction_id)
      deliver(batch, { "transaction" => transaction_id, "network" => X402::Requirements.network })
    else
      settle(batch, payload)
    end
  end

  def deliver(batch, settlement)
    licenses = []
    PurchaseBatch.transaction do
      batch.purchases.each do |purchase|
        license = purchase.license || License.allocate!(purchase)
        Sandbox::Topic.anchor!(license) if batch.sandbox? && !license.anchored?
        purchase.transition_to!(:delivered) unless purchase.delivered?
        licenses << license
      end
      batch.update!(status: "delivered")
    end
    licenses.each { |license| CertMintJob.perform_later(license.id) } unless batch.sandbox?
    licenses.each { |license| WebhookFanoutJob.perform_later(license.id, "sale.completed") } unless batch.sandbox?
    response.set_header("PAYMENT-RESPONSE", Base64.strict_encode64(JSON.generate(settlement)))
    response.set_header("X-PAYMENT-RESPONSE", response.get_header("PAYMENT-RESPONSE"))
    render json: delivery_payload(batch.reload), status: :ok
  end

  def delivery_payload(batch)
    {
      batch_id: batch.id,
      sandbox: batch.sandbox?,
      transaction_id: batch.payment_tx_id,
      hashscan_url: batch.sandbox? ? nil : "#{Hedera::Network.hashscan_base}/transaction/#{batch.payment_tx_id}",
      licenses: batch.purchases.includes(:license, license_offer: { model3d: :model_files }).map do |purchase|
        license_payload(purchase)
      end
    }
  end

  def license_payload(purchase)
    license = purchase.license
    files = if purchase.sandbox?
      [ { kind: "sandbox_receipt", url: api_v1_sandbox_file_url(license.cert_id), expires_at: nil } ]
    else
      grant = license.download_grants.detect(&:usable?) || DownloadGrant.issue!(license)
      purchase.model3d.printable_files.map do |file|
        { kind: file.kind, url: api_v1_file_url(grant.token), expires_at: grant.expires_at.iso8601 }
      end
    end
    {
      model_id: purchase.model3d.id,
      kind: purchase.license_offer.kind,
      cert_id: license.cert_id,
      serial: license.serial,
      files: files,
      verify_url: "#{request.base_url}/verify/#{license.verify_slug}"
    }
  end

  def facilitator_for(batch)
    batch.sandbox? ? Sandbox::Facilitator.new : FacilitatorClient.new
  end

  def network_for(batch)
    batch.sandbox? ? Sandbox::Requirements::NETWORK : X402::Requirements.network
  end
end
