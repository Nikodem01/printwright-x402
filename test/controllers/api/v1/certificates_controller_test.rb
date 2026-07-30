require "test_helper"

class Api::V1::CertificatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    model = Model3d.create!(
      designer: designers(:one), title: "C", slug: "c-#{SecureRandom.hex(4)}", status: "published"
    )
    offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    purchase = Purchase.create!(license_offer: offer, status: "settled", replay_key: SecureRandom.hex(32))
    @license = License.allocate!(purchase)
  end

  test "minting cert returns the reveal bundle with a pending hedera block" do
    @license.update!(cert_json: { "v" => 1, "cert_id" => @license.cert_id })
    get api_v1_certificate_url(@license.cert_id)
    assert_response :success
    body = response.parsed_body
    assert_equal "minting", body["status"]
    assert_equal "minting", body.dig("hedera", "status")
    assert_equal @license.cert_id, body.dig("certificate", "cert_id")
    # The reveal: nonce + recomputed commitment + algorithm, so a caller can
    # recompute independently once the commitment anchors.
    assert_equal "sha256-jcs-v1", body["algorithm"]
    assert_equal @license.cert_salt, body["blinding_nonce"]
    assert_equal Certificates::Commitment.digest(@license.cert_json, @license.cert_salt), body["commitment"]
  end

  test "anchored cert bundle exposes its exact mirror message link" do
    @license.update!(cert_json: { "v" => 1 }, hcs_topic_id: "0.0.9585069", hcs_sequence_number: 4)
    get api_v1_certificate_url(@license.cert_id)
    body = response.parsed_body
    assert_equal "anchored", body["status"]
    assert_equal "https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069/messages/4",
                 body.dig("hedera", "mirror_url")
    refute body.fetch("hedera").key?("hashscan_url")
  end

  test "bundle carries the exact licensed terms bytes" do
    @license.update!(cert_json: { "v" => 1 })
    get api_v1_certificate_url(@license.cert_id)
    terms = response.parsed_body["terms"]
    assert_equal @license.purchase.license_offer.terms_hash, terms["hash"]
    assert_equal @license.purchase.license_offer.terms_text, terms["text"]
  end

  test "unknown cert_id is 404" do
    get api_v1_certificate_url("pw-999999")
    assert_response :not_found
  end
end
