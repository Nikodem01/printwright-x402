require "test_helper"
require "webmock/minitest"

class Api::V1::SandboxFlowTest < ActionDispatch::IntegrationTest
  setup do
    @model = Model3d.create!(
      designer: designers(:one), title: "Sandbox Model", slug: "sandbox-#{SecureRandom.hex(4)}",
      file_hash: "sha256:#{Digest::SHA256.hexdigest('real printable bytes')}", status: "published"
    )
    file = @model.model_files.create!(kind: "stl", position: 0)
    file.file.attach(
      io: StringIO.new("REAL PRINTABLE BYTES MUST NEVER LEAVE SANDBOX"),
      filename: "private.stl", content_type: "model/stl"
    )
    @offer = @model.license_offers.create!(
      kind: "personal", price_cents: 25, max_units: 1, terms_md: "Sandbox terms."
    )
  end

  test "zero-fund sandbox completes the x402 flow with local, unmistakably fake evidence" do
    get download_path, headers: sandbox_headers

    assert_response :payment_required
    quote = response.parsed_body
    assert_equal "true", response.headers["X-Printwright-Sandbox"]
    assert_equal "x402", response.headers["WWW-Authenticate"]
    assert_equal quote, JSON.parse(Base64.strict_decode64(response.headers["PAYMENT-REQUIRED"]))
    assert_equal [ true, Sandbox::Requirements::WARNING ], [ quote["sandbox"], quote["warning"] ]
    assert_equal 1, quote["accepts"].length
    assert_equal [ "hedera:sandbox", "sandbox:credit", "sandbox:designer", "sandbox:facilitator" ],
      [ quote.dig("accepts", 0, "network"), quote.dig("accepts", 0, "asset"),
        quote.dig("accepts", 0, "payTo"), quote.dig("accepts", 0, "extra", "feePayer") ]

    payload = sandbox_payload(quote)
    assert_no_enqueued_jobs do
      get download_path, headers: sandbox_headers.merge("PAYMENT-SIGNATURE" => encode(payload))
    end

    assert_response :success
    delivery = response.parsed_body
    assert_equal "true", response.headers["X-Printwright-Sandbox"]
    assert_equal [ true, Sandbox::Requirements::WARNING, nil ],
      [ delivery["sandbox"], delivery["warning"], delivery["hashscan_url"] ]
    assert_match(/\Asandbox-tx-[0-9a-f]{20}\z/, delivery["transaction_id"])
    assert_match(/\Asandbox-pw-\d{6}\z/, delivery.dig("license", "cert_id"))
    assert_equal [ "sandbox_receipt" ], delivery["files"].pluck("kind")
    assert delivery["files"].all? { |entry| entry["sandbox"] }
    assert_includes delivery.dig("files", 0, "url"), "/api/v1/sandbox/files/"
    assert_includes delivery["sandbox_url"], "/api/v1/sandbox/transactions/"

    purchase = Purchase.sole
    license = purchase.license
    assert purchase.sandbox?
    assert purchase.delivered?
    assert_equal [ "sandbox:credit", "sandbox-buyer" ], [ purchase.asset, purchase.buyer_hint ]
    assert_equal [ Sandbox::Topic::ID, license.id ], [ license.hcs_topic_id, license.hcs_sequence_number ]
    assert_equal true, license.cert_json["sandbox"]
    assert_equal 0, LedgerEntry.where(purchase: purchase).count
    assert_equal 0, DownloadGrant.where(license: license).count

    get URI(delivery.dig("files", 0, "url")).request_uri
    assert_response :success
    assert_includes response.body, "NOT A PRINTABLE MODEL"
    assert_not_includes response.body, "REAL PRINTABLE BYTES"

    get api_v1_certificate_path(license.cert_id)
    assert_response :success
    certificate = response.parsed_body
    assert_equal "sandbox", certificate["status"]
    assert_nil certificate["nft"]
    assert_equal [ true, nil ], [ certificate.dig("hcs", "sandbox"), certificate.dig("hcs", "hashscan_url") ]

    get URI(certificate.dig("hcs", "mirror_url")).request_uri
    assert_response :success
    message = response.parsed_body
    assert_equal true, message["sandbox"]
    assert_equal license.cert_json, JSON.parse(Base64.strict_decode64(message["message"]))

    get URI(delivery["sandbox_url"]).request_uri
    assert_response :success
    assert_equal [ true, "delivered", license.cert_id ],
      response.parsed_body.values_at("sandbox", "status", "cert_id")

    get URI(delivery["verify_url"]).request_uri
    assert_response :success
    assert_select ".banner-sandbox", text: /Sandbox/i
    assert_select '.evidence-footer a[href*="hashscan.io"]', count: 0

    get verify_badge_path(license.verify_slug)
    assert_response :success
    assert_includes response.body, "SANDBOX ONLY"

    get verify_certificate_path(license.verify_slug)
    assert_response :success
    assert_select "h1", text: /Sandbox Rehearsal Certificate/
    assert_includes response.body, "grants no rights"
    assert_not_includes response.body, "Publicly anchored on Hedera"

    assert_not @offer.reload.sold_out?, "sandbox purchases must not consume a limited edition"
    real_purchase = Purchase.create!(
      license_offer: @offer, status: "settled", replay_key: SecureRandom.hex(32)
    )
    assert_equal 1, License.allocate!(real_purchase).serial
  end

  test "tampered sandbox requirements are rejected before persistence" do
    get download_path, headers: sandbox_headers
    quote = response.parsed_body
    payload = sandbox_payload(quote)
    payload["accepted"]["network"] = "hedera:testnet"

    get download_path, headers: sandbox_headers.merge("PAYMENT-SIGNATURE" => encode(payload))

    assert_response :payment_required
    assert_equal "invalid_payment_requirements", response.parsed_body["error"]
    assert_equal 0, Purchase.count
    assert_not_requested :any, %r{https?://}
  end

  private

  def download_path
    api_v1_model_download_path(@model, license: "personal")
  end

  def sandbox_headers
    { "X-Sandbox" => "true" }
  end

  def sandbox_payload(quote)
    {
      "x402Version" => 2,
      "resource" => quote.fetch("resource"),
      "accepted" => quote.fetch("accepts").sole,
      "payload" => { "transaction" => "sandbox:#{SecureRandom.uuid}" }
    }
  end

  def encode(payload)
    Base64.strict_encode64(JSON.generate(payload))
  end
end
