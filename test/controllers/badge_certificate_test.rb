require "test_helper"
require "webmock/minitest"

class BadgeCertificateTest < ActionDispatch::IntegrationTest
  setup do
    model = Model3d.create!(
      designer: designers(:one), title: "Badge Cube", slug: "badge-cube",
      status: "published", file_hash: "sha256:abc"
    )
    offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    purchase = Purchase.create!(
      license_offer: offer, status: "settled", buyer_hint: "0.0.9067781",
      asset: "0.0.429274", amount_base_units: "250000",
      payment_tx_id: "0.0.7162784@1.2", replay_key: SecureRandom.hex(32)
    )
    @license = License.allocate!(purchase)
    @license.update!(
      cert_json: Certificates::Builder.call(@license),
      hcs_topic_id: "0.0.9585069", hcs_sequence_number: 42
    )
  end

  test "badge is a self-contained SVG naming the cert id" do
    get verify_badge_path(cert_id: @license.verify_slug, format: :svg)
    assert_response :success
    assert_equal "image/svg+xml", response.media_type
    assert_match @license.cert_id, response.body
    assert_match "<svg", response.body
    assert_no_match(/<script/i, response.body)
  end

  test "printable certificate carries the QR to the live check and the raw URLs" do
    get verify_certificate_path(@license.verify_slug)
    assert_response :success
    assert_match @license.cert_id, response.body
    assert_match "svg", response.body # the QR
    assert_match verify_url(@license.verify_slug), response.body
    assert_match "mirrornode.hedera.com/api/v1/topics/0.0.9585069/messages/42", response.body
    assert_match "@page", response.body # print stylesheet present
  end

  test "share card renders certificate facts and the honest license-sale cap" do
    offer = @license.purchase.license_offer
    offer.update!(max_units: 25)
    offer.model3d.update!(title: "Useful <script>alert(1)</script> part")

    get verify_share_card_path(@license.verify_slug)

    assert_response :success
    assert_equal "image/svg+xml", response.media_type
    assert_match 'width="1200" height="630"', response.body
    assert_match @license.cert_id, response.body
    assert_match "#1 of 25", response.body
    assert_match "limits licenses sold", response.body
    assert_no_match(/<script/i, response.body)
    assert_empty Nokogiri::XML(response.body).errors
  end

  test "badge docs page shows the snippet; unknown certs 404" do
    get badge_docs_path
    assert_response :success
    assert_match "&lt;img src=", response.body
    assert_match "/verify/pw-000001/badge", response.body
    assert_match "/printwright-verify-widget.js", response.body
    assert_match "&lt;printwright-verify", response.body

    get verify_badge_path(cert_id: "pw-999999", format: :svg)
    assert_response :not_found
    get verify_certificate_path("pw-999999")
    assert_response :not_found
    get verify_share_card_path("pw-999999")
    assert_response :not_found
  end

  test "standalone widget and plain HTML example are public static assets" do
    get "/printwright-verify-widget.js"
    assert_response :success
    assert_equal "text/javascript", response.media_type
    assert_match "testnet.mirrornode.hedera.com", response.body
    assert_no_match %r{/api/v1/(models|licenses|verify)}, response.body

    get "/widget-example.html"
    assert_response :success
    assert_match "<printwright-verify", response.body
    assert_match 'cert-id="pw-000058"', response.body
  end
end
