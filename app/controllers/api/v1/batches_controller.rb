class Api::V1::BatchesController < Api::V1::BaseController
  InvalidBatch = Class.new(StandardError)

  # These two bound work, not buying. Units per line are NOT capped by either:
  # how many units an offer sells is the designer's max_units or nothing at all.
  #
  # MAX_LINE_ITEMS bounds the free, unpaid quote path — the only work a caller
  # gets without paying for it. Measured flat at 18-57ms for 1 to 200 lines
  # (two queries total, one requirements object per line), so this sits far
  # above any real order and exists only so one anonymous POST cannot be turned
  # into unbounded work.
  #
  # MAX_UNITS bounds the *paid* path, where every licence is a purchase row, a
  # serial allocated under the offer lock, a built certificate and a queued HCS
  # job. Measured at ~62ms per licence, so the cap is ~16s of delivery — inside
  # kamal-proxy's 30s target timeout with room to spare. Without it one signed
  # payment could buy a settle we cannot deliver inside a single response; the
  # replay path would recover it, but we would have taken money for a delivery
  # that times out every time, and we never refund. Raising it means either
  # making delivery cheaper per licence or moving it off the request.
  MAX_LINE_ITEMS = 200
  MAX_UNITS = 250

  # A batch is one settlement, so an agent needs far fewer of these than of the
  # single-license rail; the quote path is the only unpaid work and it is cheap.
  rate_limit to: 60, within: 1.minute, store: RateLimitStore, with: :api_rate_limited
  after_action :record_payment_request

  def create
    units = expand(normalized_items)
    webhook = normalized_webhook
    sandbox = request.headers["X-Sandbox"] == "true"
    response.set_header("X-Printwright-Sandbox", "true") if sandbox
    raw_payment = X402::PaymentHeader.raw(request)
    payload = X402::PaymentHeader.decode(request) if raw_payment
    key = replay_key(payload) if payload
    if key && Purchase.exists?(replay_key: key)
      return replay_existing(key, payload, items: units, sandbox: sandbox)
    end

    models = models_for(units)
    if (unavailable = models.find { |model| !model.published? })
      return render_listing_unavailable(unavailable)
    end
    offers = offers_for(units, models)
    requirements = X402::BatchRequirements.new(
      offers: offers, resource_url: request.original_url, sandbox: sandbox
    )

    if payload.nil?
      return render json: { error: "sold_out" }, status: :gone if !sandbox && sold_out?(offers)
      @analytics_event = {
        model_ids: models.map(&:id), event: "payment_request",
        channel: analytics_channel, source: "batch_checkout"
      } unless sandbox
      return payment_required(requirements)
    end

    matched = requirements.match(payload["accepted"])
    return payment_required(requirements, error: "invalid_payment_requirements") unless matched

    batch = reserve(offers, matched, key, sandbox: sandbox, webhook: webhook)
    return replay_existing(key, payload, items: units, sandbox: sandbox) if batch.nil?
    return render json: { error: "sold_out" }, status: :gone if batch == :sold_out
    if batch == :listing_unavailable
      unavailable = offers.map(&:model3d).uniq.find { |model| !model.reload.published? }
      return render_listing_unavailable(unavailable || offers.first.model3d)
    end
    if batch == :offer_changed
      models = models_for(units)
      if (unavailable = models.find { |model| !model.published? })
        return render_listing_unavailable(unavailable)
      end
      current = offers_for(units, models)
      current_requirements = X402::BatchRequirements.new(
        offers: current, resource_url: request.original_url, sandbox: sandbox
      )
      return payment_required(current_requirements, error: "offer_changed")
    end

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

  def record_payment_request
    Analytics::Recorder.record_later(**@analytics_event) if response.status == 402 && @analytics_event
  end

  def analytics_channel
    request.headers["X-Printwright-Channel"] == "human" ? "human" : "agent"
  end

  def normalized_items
    raw = params.require(:items)
    raise InvalidBatch unless raw.is_a?(Array) && raw.length.between?(1, MAX_LINE_ITEMS)

    items = raw.map do |item|
      item = item.permit(:model_id, :license, :quantity)
      model_id = item[:model_id].to_s
      kind = item[:license].presence || "personal"
      quantity = item[:quantity].nil? ? "1" : item[:quantity].to_s
      unless model_id.match?(/\A[1-9]\d*\z/) && LicenseOffer::KINDS.include?(kind) &&
             quantity.match?(/\A[1-9]\d*\z/)
        raise InvalidBatch
      end

      { model_id: model_id.to_i, license: kind, quantity: quantity.to_i }
    end
    raise InvalidBatch if items.sum { |item| item.fetch(:quantity) } > MAX_UNITS

    items
  end

  # One purchase, one certificate, one serial: a line asking for three units is
  # three licences. Expanding here keeps quantity a pure input convenience —
  # pricing, the offer lock, reservation, and delivery all still work in
  # licences and need no notion of it.
  def expand(items)
    items.flat_map do |item|
      Array.new(item.fetch(:quantity)) { { model_id: item.fetch(:model_id), license: item.fetch(:license) } }
    end
  end

  def models_for(items)
    ids = items.map { |item| item.fetch(:model_id) }.uniq
    models = Model3d.where(id: ids).index_by(&:id)
    raise ActiveRecord::RecordNotFound unless models.length == ids.length
    raise ActiveRecord::RecordNotFound if models.values.any?(&:draft?)

    items.map { |item| models.fetch(item.fetch(:model_id)) }
  end

  # One query for the whole batch. This used to be a find_by! per item, which
  # made the unpaid quote path scale its query count with the order — the only
  # real argument there ever was for keeping that order small.
  def offers_for(items, models)
    kinds = items.map { |item| item.fetch(:license) }.uniq
    offers = LicenseOffer.active
      .where(model3d_id: models.map(&:id).uniq, kind: kinds)
      .index_by { |offer| [ offer.model3d_id, offer.kind ] }

    items.each_with_index.map do |item, index|
      offers.fetch([ models.fetch(index).id, item.fetch(:license) ]) { raise ActiveRecord::RecordNotFound }
    end
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
      return :offer_changed if resolved.any? { |offer| !offer.active? }
      return :listing_unavailable if resolved.any? { |offer| !offer.model3d.reload.published? }
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
      undeliverable = batch.purchases.reject { |purchase| deliverable?(purchase) }
      return render_undeliverable(batch, undeliverable) if undeliverable.any?

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

  def replay_existing(key, payload, items:, sandbox:)
    existing = Purchase.find_by!(replay_key: key)
    if (batch = existing.purchase_batch)
      purchased_items = batch.purchases.order(:batch_position).map do |purchase|
        { model_id: purchase.license_offer.model3d_id, license: purchase.license_offer.kind }
      end
      if purchased_items == items && batch.sandbox? == sandbox
        return replay(batch, payload)
      end
    end

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
    if (undeliverable = batch.purchases.reject { |purchase| deliverable?(purchase) }).any?
      return render_undeliverable(batch, undeliverable)
    end

    licenses = []
    PurchaseBatch.transaction do
      batch.purchases.each do |purchase|
        license = purchase.license || License.allocate!(purchase)
        Sandbox::Topic.anchor!(license) if batch.sandbox? && !license.anchored?
        # Build the certificate now so each delivered proof bundle is complete;
        # CertMintJob then just anchors the commitment (see downloads flow).
        if !batch.sandbox? && license.cert_json.blank?
          license.update!(cert_json: Certificates::Builder.call(license))
        end
        purchase.transition_to!(:delivered) unless purchase.delivered?
        licenses << license
      end
      batch.update!(status: "delivered")
    end
    licenses.each { |license| CertMintJob.perform_later(license.id) } unless batch.sandbox?
    licenses.each { |license| WebhookFanoutJob.perform_later(license.id, "sale.completed") } unless batch.sandbox?
    unless batch.sandbox?
      DesignerPayoutJob.perform_later(purchase_ids: batch.purchases.ids, ref: "batch-#{batch.id}")
    end
    response.set_header("PAYMENT-RESPONSE", Base64.strict_encode64(JSON.generate(settlement)))
    response.set_header("X-PAYMENT-RESPONSE", response.get_header("PAYMENT-RESPONSE"))
    render json: delivery_payload(batch.reload), status: :ok
  end

  # Same rule as the single-license rail: money has moved, so a licence with no
  # downloadable file is an outage we own, not a 200. One missing file fails the
  # whole batch rather than quietly shorting the buyer on one line — the batch
  # settled as one payment and stays replayable as one.
  def deliverable?(purchase)
    purchase.sandbox? || purchase.model3d.deliverable_files.any?
  end

  def render_undeliverable(batch, undeliverable)
    batch.update!(error_reason: "no_deliverable_file")
    Rails.logger.error(
      "batch_delivery_failed batch=#{batch.id} tx=#{batch.payment_tx_id} " \
      "models=#{undeliverable.map { |purchase| purchase.model3d.id }.uniq.join(',')} reason=no_deliverable_file"
    )
    render json: {
      error: "no_deliverable_file",
      message: "Payment settled, but some models in this batch have no downloadable file right now. " \
               "Retry this exact signed batch once they are back; nothing needs to be paid again.",
      recoverable: true,
      retry_after: 60,
      batch_id: batch.id,
      transaction_id: batch.payment_tx_id,
      model_ids: undeliverable.map { |purchase| purchase.model3d.id }.uniq
    }, status: :service_unavailable
  end

  def delivery_payload(batch)
    {
      batch_id: batch.id,
      sandbox: batch.sandbox?,
      transaction_id: batch.payment_tx_id,
      transaction_url: batch.sandbox? ? nil : Hedera::Network.transaction_url(batch.payment_tx_id),
      licenses: batch.purchases.includes(:license, license_offer: { model3d: { model_files: :file_attachment } })
        .map { |purchase| license_summary(purchase) }
    }
  end

  # A summary plus where to fetch the rest, not the whole single-license payload
  # repeated N times. The full proof bundle is the bulky part and it is already
  # addressable — inlining one per licence made the response grow with the order
  # and quietly made order size a bandwidth question. `files` stays inline: the
  # file is the sale and must never sit behind a second call.
  #
  #   bundle_url    -> the portable proof bundle for this certificate
  #   receipt       -> durable, non-expiring: `${url}.json?token=` re-lists the
  #                    files, `${url}?token=` is the human receipt page, and both
  #                    carry the pdf, print-feedback, and model-update handles
  def license_summary(purchase)
    license = purchase.license
    files = if purchase.sandbox?
      [ { kind: "sandbox_receipt", url: api_v1_sandbox_file_url(license.cert_id), expires_at: nil } ]
    else
      grant = DownloadGrant.for(license)
      purchase.model3d.deliverable_files.map do |index, file|
        { kind: file.kind, url: api_v1_file_url(grant.token, f: index), expires_at: grant.expires_at.iso8601 }
      end
    end
    payload = {
      model_id: purchase.model3d.id,
      kind: purchase.license_offer.kind,
      cert_id: license.cert_id,
      serial: license.serial,
      max_units: purchase.license_offer.max_units,
      remaining_units: purchase.license_offer.units_remaining,
      files: files,
      verify_url: "#{request.base_url}/verify/#{license.verify_slug}",
      bundle_url: api_v1_certificate_url(license.cert_id),
      certificate_pdf_url: verify_certificate_pdf_url(license.verify_slug)
    }
    return payload if purchase.sandbox?

    payload[:share_card_url] = verify_share_card_url(license.verify_slug)
    payload[:receipt] = receipt_capability(license)
    payload
  end

  def receipt_capability(license)
    {
      url: purchase_receipt_url(license.cert_id),
      files_url: purchase_receipt_url(license.cert_id, format: :json),
      download_url: purchase_receipt_download_url(license.cert_id),
      package_url: purchase_receipt_package_url(license.cert_id),
      token: license.signed_id(purpose: "purchase-receipt"),
      expires_at: nil
    }
  end

  def facilitator_for(batch)
    batch.sandbox? ? Sandbox::Facilitator.new : FacilitatorClient.new
  end

  def network_for(batch)
    batch.sandbox? ? Sandbox::Requirements::NETWORK : X402::Requirements.network
  end
end
