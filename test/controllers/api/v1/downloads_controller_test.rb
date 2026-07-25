require "test_helper"
require "webmock/minitest"

# Covers every row of the plan-04 error table. The payment payload and the
# facilitator verify/settle bodies are the REAL bytes captured in the B1
# testnet spike (test/fixtures/files/x402/) — not hand-written approximations.
class Api::V1::DownloadsControllerTest < ActionDispatch::IntegrationTest
  FACILITATOR = "https://facilitator.test".freeze

  setup do
    ENV["X402_FACILITATOR_URL"] = FACILITATOR
    ENV["X402_PAY_TO"] = "0.0.9584959"
    ENV["X402_DEMO_HBAR_PRICE_CENTS"] = "250" # 25c offer => exactly 0.1 HBAR, matching the real fixture
    FacilitatorClient.reset_cache!
    stub_request(:get, "#{FACILITATOR}/supported")
      .to_return(body: fixture("supported.json"), headers: { "content-type" => "application/json" })

    @model = Model3d.create!(
      designer: designers(:one), title: "Spike Premium", slug: "spike-premium",
      file_hash: "sha256:#{Digest::SHA256.hexdigest('spike')}", status: "published"
    )
    stl = @model.model_files.create!(kind: "stl", position: 0)
    stl.file.attach(io: StringIO.new("solid t\nendsolid t\n"), filename: "t.stl", content_type: "model/stl")
    @offer = @model.license_offers.create!(kind: "personal", price_cents: 25, currency: "HBAR", terms_md: "T.")
    @payload = JSON.parse(fixture("payment_payload.json"))
  end

  teardown { FacilitatorClient.reset_cache! }

  # --- error table row: unknown model / offer kind -> 404 ---

  test "unknown model and unknown offer kind 404" do
    get download_path(id: 999_999)
    assert_response :not_found
    get download_path, params: { license: "site_wide" }
    assert_response :not_found
  end

  # --- row: no payment header -> 402 with body AND header ---

  test "bare request gets 402 with PaymentRequired in body and PAYMENT-REQUIRED header" do
    get download_path
    assert_response :payment_required
    body = response.parsed_body
    assert_equal 2, body["x402Version"]
    assert_equal 2, body["accepts"].length
    hbar = body["accepts"].first # HBAR-lead offer
    assert_equal [ "10000000", "0.0.0", "0.0.9584959", "0.0.7162784" ],
                 [ hbar["amount"], hbar["asset"], hbar["payTo"], hbar.dig("extra", "feePayer") ]
    usdc = body["accepts"].second
    assert_equal [ "250000", "0.0.429274" ], [ usdc["amount"], usdc["asset"] ]
    decoded = JSON.parse(Base64.strict_decode64(response.headers["PAYMENT-REQUIRED"]))
    assert_equal body, decoded
    assert_equal "x402", response.headers["WWW-Authenticate"]
  end

  test "initial real quote records one bounded channel event but sandbox does not" do
    clear_enqueued_jobs

    perform_enqueued_jobs(only: RecordModelMetricsJob) do
      get download_path, headers: { "X-Printwright-Channel" => "human" }
    end

    assert_response :payment_required
    metric = @model.model_metrics.find_by!(channel: "human", source: "checkout")
    assert_equal 1, metric.payment_requests

    clear_enqueued_jobs
    get download_path, headers: { "X-Sandbox" => "true", "X-Printwright-Channel" => "human" }
    assert_response :payment_required
    assert_not enqueued_jobs.any? { |job| job[:job] == RecordModelMetricsJob }
    assert_equal 1, @model.model_metrics.sum(:payment_requests)

    tampered = @payload.deep_dup
    tampered["accepted"]["amount"] = "1"
    clear_enqueued_jobs
    get download_path, headers: payment_headers(tampered).merge("X-Printwright-Channel" => "human")
    assert_response :payment_required
    assert_equal "invalid_payment_requirements", response.parsed_body["error"]
    assert_not enqueued_jobs.any? { |job| job[:job] == RecordModelMetricsJob },
      "a refreshed challenge is not a new initial quote request"
  end

  test "analytics enqueue failure never changes the 402 buyer contract" do
    singleton = RecordModelMetricsJob.singleton_class
    original = RecordModelMetricsJob.method(:perform_later)
    singleton.define_method(:perform_later) { |**| raise ActiveJob::EnqueueError, "queue unavailable" }

    get download_path, headers: { "X-Printwright-Channel" => "human" }

    assert_response :payment_required
    assert_equal "x402", response.headers["WWW-Authenticate"]
    assert response.headers["PAYMENT-REQUIRED"].present?
  ensure
    singleton&.define_method(:perform_later, original) if original
  end

  test "paused and retired listings refuse every new payment before reservation" do
    @model.update!(status: "paused")

    get download_path
    assert_response :conflict
    assert_equal({ "error" => "sales_paused", "listing_status" => "paused" }, response.parsed_body)
    get download_path, headers: payment_headers(@payload)
    assert_response :conflict
    assert_equal 0, Purchase.count
    assert_not_requested :post, "#{FACILITATOR}/verify"

    @model.update!(status: "retired")
    get download_path
    assert_response :gone
    assert_equal({ "error" => "listing_retired", "listing_status" => "retired" }, response.parsed_body)
    assert_equal 0, Purchase.count
  end

  # --- row: malformed header -> 400 invalid_payload ---

  test "malformed payment headers get 400 invalid_payload" do
    [ "not base64!!!", Base64.strict_encode64("not json"), Base64.strict_encode64('"42"'),
      Base64.strict_encode64('{"accepted": {}, "payload": {}}') ].each do |header|
      get download_path, headers: { "PAYMENT-SIGNATURE" => header }
      assert_response :bad_request
      assert_equal "invalid_payload", response.parsed_body["error"]
    end
    assert_equal 0, Purchase.count
  end

  # --- row: accepted mismatch -> 402 fresh PaymentRequired ---

  test "tampered amount gets 402 invalid_payment_requirements and no purchase row" do
    tampered = @payload.deep_dup
    tampered["accepted"]["amount"] = "1"
    get download_path, headers: payment_headers(tampered)
    assert_response :payment_required
    assert_equal "invalid_payment_requirements", response.parsed_body["error"]
    assert_equal 0, Purchase.count
  end

  test "a signed quote for a superseded offer receives the current revision challenge" do
    Purchase.create!(license_offer: @offer, status: "pending", replay_key: SecureRandom.hex(32))
    current = LicenseOffers::Reviser.call(model: @model,
      attributes: { id: @offer.id, kind: "personal", price_cents: 50, currency: "HBAR" })

    get download_path, headers: payment_headers(@payload)

    assert_response :payment_required
    assert_equal "invalid_payment_requirements", response.parsed_body["error"]
    hbar = response.parsed_body.fetch("accepts").find { |option| option["asset"] == "0.0.0" }
    assert_equal "20000000", hbar.fetch("amount")
    assert_equal current.id, @model.reload.license_offers.sole.id
    assert_equal 1, Purchase.count
  end

  test "reservation refuses an offer object that became inactive after lookup" do
    stale = @offer
    Purchase.create!(license_offer: stale, status: "pending", replay_key: SecureRandom.hex(32))
    LicenseOffers::Reviser.call(model: @model,
      attributes: { id: stale.id, kind: "personal", price_cents: 50, currency: "HBAR" })

    result = Api::V1::DownloadsController.new.send(:create_purchase, stale, @payload,
      { asset: "0.0.0", amount: "10000000" }, sandbox: false)

    assert_equal :offer_changed, result
    assert_equal 1, Purchase.count
  end

  # --- happy path (real bytes end to end) ---

  test "paid request verifies, settles, delivers, and both response headers decode" do
    stub_verify_ok
    stub_settle(body: fixture("settle_ok.json"))

    # Cert minting is async by design: a sidecar outage must never block delivery.
    assert_enqueued_with(job: CertMintJob) do
      get download_path, headers: payment_headers(@payload)
    end
    assert_response :success

    body = response.parsed_body
    assert_equal "0.0.7162784@1784125705.137810120", body["transaction_id"]
    assert_includes body["hashscan_url"], body["transaction_id"]
    assert_equal 1, body.dig("license", "serial")
    assert_match(/\Apw-[0-9a-f]{24}\z/, body.dig("license", "cert_id"))

    # The agent receives a portable proof bundle it can verify against Hedera
    # without us, plus a URL to re-fetch it once the commitment anchors.
    bundle = body.fetch("proof_bundle")
    assert_equal "sha256-jcs-v1", bundle["algorithm"]
    assert_equal body.dig("license", "cert_id"), bundle.dig("certificate", "cert_id")
    assert bundle["blinding_nonce"].present?
    assert_equal Certificates::Commitment.digest(bundle["certificate"], bundle["blinding_nonce"]),
                 bundle["commitment"]
    assert_includes body["bundle_url"], "/api/v1/certificates/#{body.dig('license', 'cert_id')}"
    assert_includes body["share_card_url"], "/share-card"
    receipt = body.fetch("receipt")
    assert_includes receipt["url"], "/receipts/#{body.dig('license', 'cert_id')}"
    assert_equal body.dig("license", "cert_id"),
      License.find_signed(receipt["token"], purpose: "purchase-receipt").cert_id
    assert_equal 1, body["files"].length
    assert_includes body["files"].first["url"], "/api/v1/files/"
    assert_includes body["files"].first["url"], "f=0" # per-file index for multi-part bundles
    feedback = body.fetch("print_feedback")
    assert_includes feedback["url"], "/api/v1/licenses/#{body.dig('license', 'cert_id')}/print_reports"
    assert_equal body.dig("license", "cert_id"),
      License.find_signed(feedback["receipt_token"], purpose: "print-feedback").cert_id
    updates = body.fetch("model_updates")
    assert_includes updates["url"], "/latest-version"
    assert_equal body.dig("license", "cert_id"),
      License.find_signed(updates["receipt_token"], purpose: "model-updates").cert_id

    purchase = Purchase.sole
    assert purchase.delivered?
    assert_equal "0.0.9067781", purchase.buyer_hint
    assert_equal "0.0.0", purchase.asset
    assert_enqueued_with(job: WebhookFanoutJob, args: [ purchase.license.id, "sale.completed" ])
    assert_enqueued_with(job: DesignerPayoutJob) # designer paid their share out of treasury custody

    settle = JSON.parse(Base64.strict_decode64(response.headers["PAYMENT-RESPONSE"]))
    assert settle["success"]
    assert_equal response.headers["PAYMENT-RESPONSE"], response.headers["X-PAYMENT-RESPONSE"]

    # the facilitator got the exact v2 request shape (matches B1's real capture)
    real = JSON.parse(fixture("verify_request.json"))
    assert_requested(:post, "#{FACILITATOR}/verify") do |req|
      sent = JSON.parse(req.body)
      sent["x402Version"] == 2 &&
        sent["paymentPayload"] == real["paymentPayload"] &&
        sent["paymentRequirements"] == real["paymentRequirements"]
    end
  end

  test "a seller-notification failure during webhook fanout never touches the buyer's delivery response" do
    stub_verify_ok
    stub_settle(body: fixture("settle_ok.json"))
    singleton = SellerNotification.singleton_class
    original = SellerNotification.method(:record!)
    singleton.define_method(:record!) { |**| raise "boom" }

    perform_enqueued_jobs(only: WebhookFanoutJob) do
      get download_path, headers: payment_headers(@payload)
    end

    assert_response :success
    assert Purchase.sole.delivered?
    assert_empty SellerNotification.all
  ensure
    singleton&.define_method(:record!, original) if original
  end

  test "v1 X-PAYMENT header name is accepted too" do
    stub_verify_ok
    stub_settle(body: fixture("settle_ok.json"))
    get download_path, headers: { "X-PAYMENT" => encode(@payload) }
    assert_response :success
  end

  test "settle response with transactionId key (scheme-spec variant) is accepted" do
    stub_verify_ok
    stub_settle(body: fixture("settle_ok_txid_variant.json"))
    get download_path, headers: payment_headers(@payload)
    assert_response :success
    assert_equal "0.0.7162784@1784125705.137810120", Purchase.sole.payment_tx_id
  end

  # --- row: verify invalid -> 402, failed_verification ---

  test "invalid verification gets 402 with the facilitator reason" do
    stub_verify(body: fixture("verify_invalid.json"))
    get download_path, headers: payment_headers(@payload)
    assert_response :payment_required
    assert_equal "invalid_signature", response.parsed_body["error"]
    assert Purchase.sole.failed_verification?
  end

  # --- row: settle failure -> 402, failed_settlement ---

  test "failed settlement gets 402 with the facilitator reason" do
    stub_verify_ok
    stub_settle(body: fixture("settle_failed.json"))
    get download_path, headers: payment_headers(@payload)
    assert_response :payment_required
    assert_equal "transaction_failed", response.parsed_body["error"]
    assert Purchase.sole.failed_settlement?
  end

  # --- row: facilitator unreachable -> 503, purchase never failed ---

  test "verify timeout gets 503 and keeps the purchase pending" do
    stub_request(:post, "#{FACILITATOR}/verify").to_timeout
    get download_path, headers: payment_headers(@payload)
    assert_response :service_unavailable
    assert_equal({ "error" => "facilitator_unavailable", "retry_after" => 5 }, response.parsed_body)
    assert Purchase.sole.pending?
  end

  test "settle timeout gets 503 and keeps the purchase verified (money may have moved)" do
    stub_verify_ok
    stub_request(:post, "#{FACILITATOR}/settle").to_timeout
    get download_path, headers: payment_headers(@payload)
    assert_response :service_unavailable
    purchase = Purchase.sole
    assert purchase.verified?
    assert_equal "facilitator_unavailable", purchase.error_reason
  end

  # --- the reconcile path: replay after settle timeout ---

  test "replay after settle timeout reconciles via mirror and delivers" do
    stub_verify_ok
    stub_request(:post, "#{FACILITATOR}/settle").to_timeout
    get download_path, headers: payment_headers(@payload)
    assert_response :service_unavailable

    mirror_tx = { transactions: [ { result: "SUCCESS", transaction_id: "0.0.7162784-1784125705-137810120",
                                    transfers: [ { account: "0.0.9584959", amount: 10_000_000 } ] } ] }
    stub_request(:get, %r{testnet\.mirrornode\.hedera\.com/api/v1/transactions})
      .to_return(body: JSON.generate(mirror_tx), headers: { "content-type" => "application/json" })

    get download_path, headers: payment_headers(@payload)
    assert_response :success
    purchase = Purchase.sole
    assert purchase.delivered?
    assert_equal "0.0.7162784@1784125705.137810120", purchase.payment_tx_id
  end

  test "replay after settle timeout with empty mirror retries settle" do
    stub_verify_ok
    stub_request(:post, "#{FACILITATOR}/settle").to_timeout
    get download_path, headers: payment_headers(@payload)
    assert_response :service_unavailable

    stub_request(:get, %r{testnet\.mirrornode\.hedera\.com/api/v1/transactions})
      .to_return(body: '{"transactions":[]}', headers: { "content-type" => "application/json" })
    stub_settle(body: fixture("settle_ok.json"))

    get download_path, headers: payment_headers(@payload)
    assert_response :success
    assert Purchase.sole.delivered?
  end

  # --- row: replay -> 409 (idempotent delivery / conflict) ---

  test "replaying a delivered purchase gets 409 with the original delivery payload" do
    stub_verify_ok
    stub_settle(body: fixture("settle_ok.json"))
    get download_path, headers: payment_headers(@payload)
    assert_response :success
    original = response.parsed_body

    @model.update!(status: "paused")

    get download_path, headers: payment_headers(@payload)
    assert_response :conflict
    replayed = response.parsed_body
    assert_equal original["license"], replayed["license"]
    assert_equal original["transaction_id"], replayed["transaction_id"]
    assert_equal 1, Purchase.count
    assert_requested :post, "#{FACILITATOR}/settle", times: 1

    get download_path, params: { license: "commercial_unit" }, headers: payment_headers(@payload)
    assert_response :conflict
    assert_equal "duplicate_payment", response.parsed_body["error"]
    assert_not response.parsed_body.key?("files")
  end

  test "an in-flight purchase remains recoverable after the listing retires" do
    stub_request(:post, "#{FACILITATOR}/verify").to_timeout
    get download_path, headers: payment_headers(@payload)
    assert_response :service_unavailable
    assert Purchase.sole.pending?

    @model.update!(status: "retired")
    stub_verify_ok
    stub_settle(body: fixture("settle_ok.json"))
    get download_path, headers: payment_headers(@payload)

    assert_response :success
    assert Purchase.sole.delivered?
  end

  test "replaying a settled purchase finishes the crashed delivery" do
    Purchase.create!(
      license_offer: @offer, status: "settled",
      replay_key: Digest::SHA256.hexdigest(@payload.dig("payload", "transaction")),
      requirements_json: { "payTo" => "0.0.9584959", "amount" => "10000000", "asset" => "0.0.0" },
      payment_tx_id: "0.0.7162784@1784125705.137810120"
    )
    get download_path, headers: payment_headers(@payload)
    assert_response :success
    assert Purchase.sole.delivered?
    assert_equal 1, response.parsed_body.dig("license", "serial")
  end

  test "replay after verify timeout retries verification (money never moved)" do
    stub_request(:post, "#{FACILITATOR}/verify").to_timeout
    get download_path, headers: payment_headers(@payload)
    assert_response :service_unavailable
    assert Purchase.sole.pending?

    stub_verify_ok
    stub_settle(body: fixture("settle_ok.json"))
    get download_path, headers: payment_headers(@payload)
    assert_response :success
    assert Purchase.sole.delivered?
  end

  test "a capacity overrun at allocation is an honest 410 with the tx id, not a 500" do
    @offer.update!(max_units: 1)
    winner = Purchase.create!(license_offer: @offer, status: "settled", replay_key: SecureRandom.hex(32))
    License.allocate!(winner)

    loser = Purchase.create!(
      license_offer: @offer, status: "settled",
      replay_key: Digest::SHA256.hexdigest(@payload.dig("payload", "transaction")),
      requirements_json: { "payTo" => "0.0.9584959", "amount" => "10000000", "asset" => "0.0.0" },
      payment_tx_id: "0.0.7162784@999.888"
    )
    get download_path, headers: payment_headers(@payload)
    assert_response :gone
    body = response.parsed_body
    assert_equal [ "sold_out", "0.0.7162784@999.888" ], [ body["error"], body["transaction_id"] ]
    assert_equal "capacity_overrun", loser.reload.error_reason
  end

  test "replaying a failed purchase gets 409 conflict" do
    stub_verify(body: fixture("verify_invalid.json"))
    get download_path, headers: payment_headers(@payload)
    assert_response :payment_required

    get download_path, headers: payment_headers(@payload)
    assert_response :conflict
    assert_equal "duplicate_payment", response.parsed_body["error"]
  end

  # --- row: max_units exhausted -> 410 ---

  test "sold-out offer gets 410 before any payment is asked for" do
    @offer.update!(max_units: 1)
    settled = Purchase.create!(license_offer: @offer, status: "settled", replay_key: SecureRandom.hex(32))
    License.allocate!(settled)

    get download_path
    assert_response :gone
    assert_equal "sold_out", response.parsed_body["error"]
  end

  # --- row: HBAR quote drift mid-purchase ---

  test "a quote that drifts within tolerance does not break an in-flight payment" do
    # 402 was issued at 250 c/hbar (fixture amount 10000000 tinybars); the
    # rate moves ~3% before the signed retry lands. Payment must still clear,
    # and the purchase must record what the buyer actually signed.
    ENV["X402_DEMO_HBAR_PRICE_CENTS"] = "257"
    stub_verify_ok
    stub_settle(body: fixture("settle_ok.json"))

    get download_path, headers: payment_headers(@payload)
    assert_response :success
    assert_equal "10000000", Purchase.sole.amount_base_units
  ensure
    ENV["X402_DEMO_HBAR_PRICE_CENTS"] = "250"
  end

  test "HBAR tolerance includes its exact lower boundary" do
    payload = @payload.deep_dup
    payload["accepted"]["amount"] = "9700000"
    stub_verify_ok
    stub_settle(body: fixture("settle_ok.json"))

    get download_path, headers: payment_headers(payload)
    assert_response :success
    assert_equal "9700000", Purchase.sole.amount_base_units
  end

  test "HBAR tolerance includes its exact upper boundary" do
    payload = @payload.deep_dup
    payload["accepted"]["amount"] = "10300000"
    stub_verify_ok
    stub_settle(body: fixture("settle_ok.json"))

    get download_path, headers: payment_headers(payload)
    assert_response :success
    assert_equal "10300000", Purchase.sole.amount_base_units
  end

  test "HBAR tolerance rejects amounts outside either boundary and enormous overpayment" do
    [ "-1", "0", "9699999", "10300001", "999999999999999999999999" ].each do |amount|
      payload = @payload.deep_dup
      payload["accepted"]["amount"] = amount

      get download_path, headers: payment_headers(payload)
      assert_response :payment_required
      assert_equal "invalid_payment_requirements", response.parsed_body["error"]
    end
    assert_equal 0, Purchase.count
  end

  test "a quote drift beyond tolerance rejects the payment before any money moves" do
    ENV["X402_DEMO_HBAR_PRICE_CENTS"] = "125" # rate halved: buyer's amount is now ~50% short
    get download_path, headers: payment_headers(@payload)
    assert_response :payment_required
    assert_equal "invalid_payment_requirements", response.parsed_body["error"]
    assert_equal 0, Purchase.count
  ensure
    ENV["X402_DEMO_HBAR_PRICE_CENTS"] = "250"
  end

  test "payTo is always the treasury, even for a verified designer (destination-charge model)" do
    get download_path
    assert(response.parsed_body["accepts"].all? { |a| a["payTo"] == "0.0.9584959" })

    # A verified payout account no longer routes the settle to the designer:
    # the treasury is merchant-of-record (fee captured atomically at settle) and
    # the designer is paid their share out via DesignerPayoutJob.
    designers(:one).update!(hedera_account_id: "0.0.9604186")
    designers(:one).update!(payout_account_verified_at: Time.current)
    get download_path
    assert(response.parsed_body["accepts"].all? { |a| a["payTo"] == "0.0.9584959" })
  end

  test "an in-flight purchase reserves capacity: second payment is refused before money moves" do
    @offer.update!(max_units: 1)
    # No license allocated yet — the rival payment is mid-settle.
    Purchase.create!(license_offer: @offer, status: "verified", replay_key: SecureRandom.hex(32))

    get download_path, headers: payment_headers(@payload)
    assert_response :gone
    assert_equal "sold_out", response.parsed_body["error"]
    assert_equal 1, Purchase.count, "the refused payment must not create a purchase"
  end

  test "failed purchases release their reserved capacity" do
    @offer.update!(max_units: 1)
    Purchase.create!(license_offer: @offer, status: "failed_verification", replay_key: SecureRandom.hex(32))

    stub_verify_ok
    stub_settle(body: fixture("settle_ok.json"))
    get download_path, headers: payment_headers(@payload)
    assert_response :success
  end

  test "chat intent binds the signed retry to one approved route and completes with delivery" do
    get download_path, params: { license: "personal" }
    usdc = response.parsed_body["accepts"].find { |accept| accept["asset"] == X402::Requirements.usdc_asset }
    payload = @payload.deep_dup
    payload["accepted"] = usdc
    purchase_path = "#{download_path}?license=personal"
    proposal = {
      "nonce" => "download-intent",
      "state" => "approved",
      "model_id" => @model.id,
      "license_kind" => "personal",
      "price_cents" => 25,
      "purchase_path" => purchase_path,
      "expires_at" => 10.minutes.from_now.iso8601,
      "approved_asset" => usdc["asset"],
      "approved_amount" => usdc["amount"]
    }
    conversation = ChatConversation.create!(purchase_proposal: proposal, approved_spend_cents: 25)
    intent = Chat::PurchaseIntent.issue(conversation: conversation, proposal: proposal)
    stub_verify_ok
    stub_settle(body: fixture("settle_ok.json"))

    get download_path, params: { license: "personal" },
      headers: payment_headers(payload).merge(Chat::PurchaseIntent::HEADER => intent)

    assert_response :success
    assert_equal "completed", conversation.reload.purchase_proposal["state"]
    assert Purchase.sole.delivered?
  end

  test "tampered chat intent is refused before a purchase or facilitator call" do
    get download_path, params: { license: "personal" },
      headers: payment_headers(@payload).merge(Chat::PurchaseIntent::HEADER => "tampered")

    assert_response :forbidden
    assert_equal "invalid_purchase_intent", response.parsed_body["error"]
    assert_equal 0, Purchase.count
    assert_not_requested :post, "#{FACILITATOR}/verify"
  end

  private

  def download_path(id: nil)
    "/api/v1/models/#{id || @model.id}/download"
  end

  def fixture(name)
    file_fixture("x402/#{name}").read
  end

  def encode(payload)
    Base64.strict_encode64(JSON.generate(payload))
  end

  def payment_headers(payload = @payload)
    { "PAYMENT-SIGNATURE" => encode(payload) }
  end

  def stub_verify(body:)
    stub_request(:post, "#{FACILITATOR}/verify")
      .to_return(body: body, headers: { "content-type" => "application/json" })
  end

  def stub_verify_ok
    stub_verify(body: fixture("verify_ok.json"))
  end

  def stub_settle(body:)
    stub_request(:post, "#{FACILITATOR}/settle")
      .to_return(body: body, headers: { "content-type" => "application/json" })
  end
end
