require "test_helper"
require "webmock/minitest"

class Api::V1::BatchesControllerTest < ActionDispatch::IntegrationTest
  FACILITATOR = "https://facilitator.test".freeze

  setup do
    ENV["X402_FACILITATOR_URL"] = FACILITATOR
    ENV["X402_PAY_TO"] = "0.0.9584959"
    ENV["X402_DEMO_HBAR_PRICE_CENTS"] = "250"
    FacilitatorClient.reset_cache!
    stub_request(:get, "#{FACILITATOR}/supported").to_return(
      body: file_fixture("x402/supported.json").read,
      headers: { "content-type" => "application/json" }
    )

    @model = designers(:one).models3d.create!(
      title: "Farm bracket", slug: "farm-bracket-#{SecureRandom.hex(4)}",
      status: "published", file_hash: "sha256:#{'a' * 64}"
    )
    file = @model.model_files.create!(kind: "stl")
    file.file.attach(io: StringIO.new("solid b\nendsolid b\n"), filename: "bracket.stl", content_type: "model/stl")
    @offer = @model.license_offers.create!(kind: "commercial_unit", price_cents: 25, currency: "USDC")
    @items = Array.new(3) { { model_id: @model.id, license: "commercial_unit" } }
  end

  teardown { FacilitatorClient.reset_cache! }

  test "one 402 quotes the exact sum for three licenses" do
    post api_v1_batches_path, params: { items: @items }, as: :json

    assert_response :payment_required
    usdc = response.parsed_body.fetch("accepts").find { |option| option["asset"] == X402::Requirements.usdc_asset }
    assert_equal "750000", usdc["amount"]
    assert_equal "0.0.9584959", usdc["payTo"]
    assert_equal 3, response.parsed_body.dig("batch", "license_count")
    assert_equal response.parsed_body,
      JSON.parse(Base64.strict_decode64(response.headers.fetch("PAYMENT-REQUIRED")))
  end

  test "machine POST receives JSON x402 challenge when browser CSRF protection is enabled" do
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    post api_v1_batches_path, params: { items: @items }, as: :json

    assert_response :payment_required
    assert_equal "application/json", response.media_type
    assert_equal 2, response.parsed_body["x402Version"]
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  test "one settlement delivers three licenses and queues three certificates" do
    accepted = challenge.fetch("accepts").find { |option| option["asset"] == X402::Requirements.usdc_asset }
    payload = payment_payload(accepted)
    stub_verify(payload, accepted)
    stub_settle(payload, accepted)

    assert_enqueued_jobs 3, only: CertMintJob do
      post api_v1_batches_path, params: { items: @items }, as: :json,
        headers: { "PAYMENT-SIGNATURE" => encode(payload) }
    end

    assert_response :success
    body = response.parsed_body
    assert_equal 3, body.fetch("licenses").length
    assert_equal 3, body.fetch("licenses").map { |item| item["cert_id"] }.uniq.length
    assert(body.fetch("licenses").all? { |item| item["verify_url"].include?(item["cert_id"]) })
    assert(body.fetch("licenses").all? { |item| item["share_card_url"].include?(item["cert_id"]) })
    assert(body.fetch("licenses").all? do |item|
      License.find_signed(item.dig("receipt", "token"), purpose: "purchase-receipt").cert_id == item["cert_id"]
    end)
    assert(body.fetch("licenses").all? do |item|
      License.find_signed(item.dig("print_feedback", "receipt_token"), purpose: "print-feedback").cert_id == item["cert_id"]
    end)
    assert(body.fetch("licenses").all? do |item|
      License.find_signed(item.dig("model_updates", "receipt_token"), purpose: "model-updates").cert_id == item["cert_id"]
    end)
    assert_equal [ "delivered" ], Purchase.distinct.pluck(:status)
    assert_equal 3, Purchase.count
    assert_equal [ "0.0.7162784@1784457000.123456789" ], Purchase.distinct.pluck(:payment_tx_id)
    assert_equal 6, LedgerEntry.count
    assert_equal 750_000, LedgerEntry.where(entry_kind: %w[designer_share platform_fee]).sum { |row| row.amount_base_units.to_i }
    assert_equal 3, enqueued_jobs.count { |entry| entry[:job] == WebhookFanoutJob }
  end

  test "replay returns the original three licenses without double settlement" do
    accepted = challenge.fetch("accepts").find { |option| option["asset"] == X402::Requirements.usdc_asset }
    payload = payment_payload(accepted)
    stub_verify(payload, accepted)
    stub_settle(payload, accepted)

    post api_v1_batches_path, params: { items: @items }, as: :json,
      headers: { "PAYMENT-SIGNATURE" => encode(payload) }
    original = response.parsed_body.fetch("licenses")
    post api_v1_batches_path, params: { items: @items }, as: :json,
      headers: { "PAYMENT-SIGNATURE" => encode(payload) }

    assert_response :conflict
    assert_equal original, response.parsed_body.fetch("licenses")
    assert_equal 3, Purchase.count
    assert_requested :post, "#{FACILITATOR}/settle", times: 1
  end

  test "capacity and payee incompatibility are rejected before payment" do
    @offer.update!(max_units: 2)
    post api_v1_batches_path, params: { items: @items }, as: :json
    assert_response :gone
    assert_equal "sold_out", response.parsed_body["error"]

    @offer.update!(max_units: nil)
    second_designer = designers(:two)
    second_designer.update!(hedera_account_id: "0.0.9604186")
    second_designer.update!(payout_account_verified_at: Time.current)
    second_model = second_designer.models3d.create!(
      title: "Direct paid", slug: "direct-paid-#{SecureRandom.hex(4)}",
      status: "published", file_hash: "sha256:#{'b' * 64}"
    )
    second_offer = second_model.license_offers.create!(kind: "commercial_unit", price_cents: 25)
    mixed = [ @items.first, { model_id: second_model.id, license: second_offer.kind } ]

    post api_v1_batches_path, params: { items: mixed }, as: :json
    assert_response :unprocessable_entity
    assert_equal "incompatible_payees", response.parsed_body["error"]
    assert_equal 0, Purchase.count
  end

  test "verify timeout keeps the reservation retryable" do
    accepted = challenge.fetch("accepts").find { |option| option["asset"] == X402::Requirements.usdc_asset }
    payload = payment_payload(accepted)
    stub_request(:post, "#{FACILITATOR}/verify").to_timeout

    post api_v1_batches_path, params: { items: @items }, as: :json,
      headers: { "PAYMENT-SIGNATURE" => encode(payload) }
    assert_response :service_unavailable
    assert PurchaseBatch.sole.pending?
    assert_equal [ "pending" ], Purchase.distinct.pluck(:status)

    stub_verify(payload, accepted)
    stub_settle(payload, accepted)
    post api_v1_batches_path, params: { items: @items }, as: :json,
      headers: { "PAYMENT-SIGNATURE" => encode(payload) }
    assert_response :success
    assert PurchaseBatch.sole.delivered?
  end

  test "settle timeout reconciles the aggregate transfer before retrying settlement" do
    accepted = challenge.fetch("accepts").find { |option| option["asset"] == X402::Requirements.usdc_asset }
    payload = payment_payload(accepted)
    stub_verify(payload, accepted)
    stub_request(:post, "#{FACILITATOR}/settle").to_timeout

    post api_v1_batches_path, params: { items: @items }, as: :json,
      headers: { "PAYMENT-SIGNATURE" => encode(payload) }
    assert_response :service_unavailable
    assert PurchaseBatch.sole.verified?

    mirror = {
      transactions: [ {
        result: "SUCCESS", transaction_id: "0.0.7162784-1784457000-123456789",
        token_transfers: [ {
          token_id: X402::Requirements.usdc_asset, account: "0.0.9584959", amount: 750_000
        } ]
      } ]
    }
    stub_request(:get, %r{testnet\.mirrornode\.hedera\.com/api/v1/transactions})
      .to_return(body: JSON.generate(mirror), headers: { "content-type" => "application/json" })

    post api_v1_batches_path, params: { items: @items }, as: :json,
      headers: { "PAYMENT-SIGNATURE" => encode(payload) }
    assert_response :success
    assert_equal "0.0.7162784@1784457000.123456789", PurchaseBatch.sole.payment_tx_id
    assert_requested :post, "#{FACILITATOR}/settle", times: 1
  end

  test "malformed, empty, and oversized batches fail without a reservation" do
    [ nil, [], Array.new(21) { @items.first }, [ { model_id: "nope" } ] ].each do |items|
      post api_v1_batches_path, params: { items: items }, as: :json
      assert_response :bad_request
      assert_equal "invalid_batch", response.parsed_body["error"]
    end
    assert_equal 0, PurchaseBatch.count
    assert_equal 0, Purchase.count
  end

  test "HBAR quote drift is distributed exactly across child licenses" do
    @offer.update!(currency: "HBAR")
    hbar = challenge.fetch("accepts").find { |option| option["asset"] == X402::Requirements::HBAR_ASSET }
    assert_equal "30000000", hbar["amount"]
    hbar["amount"] = "29100000"
    payload = payment_payload(hbar)
    stub_verify(payload, hbar)
    stub_settle(payload, hbar)

    post api_v1_batches_path, params: { items: @items }, as: :json,
      headers: { "PAYMENT-SIGNATURE" => encode(payload) }

    assert_response :success
    assert_equal [ "9700000" ], Purchase.distinct.pluck(:amount_base_units)
    assert_equal 29_100_000, Purchase.sum { |purchase| purchase.amount_base_units.to_i }
  end

  test "sandbox rehearses one batch negotiation without files, funds, or HCS" do
    headers = { "X-Sandbox" => "true" }
    post api_v1_batches_path, params: { items: @items }, as: :json, headers: headers
    assert_response :payment_required
    accepted = response.parsed_body.fetch("accepts").sole
    payload = {
      "x402Version" => 2,
      "accepted" => accepted,
      "payload" => { "transaction" => "sandbox:9f36e06c-4446-4e52-84b8-b5b1ddea61c4" }
    }

    assert_no_enqueued_jobs only: CertMintJob do
      post api_v1_batches_path, params: { items: @items }, as: :json,
        headers: headers.merge("PAYMENT-SIGNATURE" => encode(payload))
    end

    assert_response :success
    assert_equal true, response.parsed_body["sandbox"]
    assert_nil response.parsed_body["hashscan_url"]
    assert_equal 3, response.parsed_body.fetch("licenses").length
    assert(response.parsed_body.fetch("licenses").all? { |item| item.dig("files", 0, "kind") == "sandbox_receipt" })
    assert(response.parsed_body.fetch("licenses").none? { |item| item.key?("print_feedback") })
    assert(response.parsed_body.fetch("licenses").none? { |item| item.key?("model_updates") })
    assert PurchaseBatch.sole.sandbox?
    assert(Purchase.all.all? { |purchase| purchase.license.cert_json["sandbox"] == true })
  end

  test "simulated 50-job farm burst settles cleanly across max-size batches" do
    assert_no_enqueued_jobs do
      [ 20, 20, 10 ].each do |size|
        items = Array.new(size) { @items.first }
        headers = { "X-Sandbox" => "true" }
        post api_v1_batches_path, params: { items: items }, as: :json, headers: headers
        assert_response :payment_required
        payload = {
          "x402Version" => 2,
          "accepted" => response.parsed_body.fetch("accepts").sole,
          "payload" => { "transaction" => "sandbox:#{SecureRandom.uuid}" }
        }

        post api_v1_batches_path, params: { items: items }, as: :json,
          headers: headers.merge("PAYMENT-SIGNATURE" => encode(payload))
        assert_response :success
        assert_equal size, response.parsed_body.fetch("licenses").size
      end
    end

    assert_equal [ 3, 50, 50 ], [ PurchaseBatch.count, Purchase.count, License.count ]
    assert PurchaseBatch.all.all?(&:sandbox?)
    assert Purchase.all.all?(&:delivered?)
  end

  test "a payment already presented to the single-license rail cannot be reused as a one-item batch" do
    one_item = [ @items.first ]
    post api_v1_batches_path, params: { items: one_item }, as: :json
    accepted = response.parsed_body.fetch("accepts").find { |option| option["asset"] == X402::Requirements.usdc_asset }
    payload = payment_payload(accepted)
    Purchase.create!(
      license_offer: @offer, replay_key: Digest::SHA256.hexdigest(payload.dig("payload", "transaction")),
      status: "delivered"
    )

    post api_v1_batches_path, params: { items: one_item }, as: :json,
      headers: { "PAYMENT-SIGNATURE" => encode(payload) }

    assert_response :conflict
    assert_equal "duplicate_payment", response.parsed_body["error"]
    assert_equal 0, PurchaseBatch.count
  end

  test "buyer certificate callback is validated and encrypted with the paid batch" do
    secret = "buyer_#{SecureRandom.hex(32)}"
    body = {
      items: @items,
      webhook: { url: "https://buyer.example/certificates", secret: secret }
    }
    accepted = challenge(body).fetch("accepts").find { |option| option["asset"] == X402::Requirements.usdc_asset }
    payload = payment_payload(accepted)
    stub_verify(payload, accepted)
    stub_settle(payload, accepted)

    post api_v1_batches_path, params: body, as: :json,
      headers: { "PAYMENT-SIGNATURE" => encode(payload) }

    assert_response :success
    batch = PurchaseBatch.sole
    assert_equal "https://buyer.example/certificates", batch.webhook_url
    assert_not_includes batch.webhook_secret_ciphertext, secret
    assert_equal secret, Webhooks::SecretBox.decrypt(batch.webhook_secret_ciphertext)
  end

  private

  def challenge(body = { items: @items })
    post api_v1_batches_path, params: body, as: :json
    assert_response :payment_required
    response.parsed_body
  end

  def payment_payload(accepted)
    {
      "x402Version" => 2,
      "accepted" => accepted,
      "payload" => { "transaction" => "signed-batch-transaction" }
    }
  end

  def encode(payload)
    Base64.strict_encode64(JSON.generate(payload))
  end

  def stub_verify(payload, accepted)
    stub_request(:post, "#{FACILITATOR}/verify").with do |request|
      body = JSON.parse(request.body)
      body["paymentPayload"] == payload && body["paymentRequirements"] == accepted
    end.to_return(
      body: JSON.generate(isValid: true, payer: "0.0.9067781"),
      headers: { "content-type" => "application/json" }
    )
  end

  def stub_settle(payload, accepted)
    stub_request(:post, "#{FACILITATOR}/settle").with do |request|
      body = JSON.parse(request.body)
      body["paymentPayload"] == payload && body["paymentRequirements"] == accepted
    end.to_return(
      body: JSON.generate(success: true, transaction: "0.0.7162784@1784457000.123456789"),
      headers: { "content-type" => "application/json" }
    )
  end
end
