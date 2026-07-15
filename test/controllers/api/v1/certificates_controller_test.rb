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

  test "minting cert has null hcs block and minting status" do
    @license.update!(cert_json: { "v" => 1, "cert_id" => @license.cert_id })
    get api_v1_certificate_url(@license.cert_id)
    assert_response :success
    body = response.parsed_body
    assert_equal [ "minting", nil ], [ body["status"], body["hcs"] ]
    assert_equal @license.cert_id, body.dig("certificate", "cert_id")
  end

  test "anchored cert exposes mirror and hashscan links" do
    @license.update!(cert_json: { "v" => 1 }, hcs_topic_id: "0.0.9585069", hcs_sequence_number: 4)
    get api_v1_certificate_url(@license.cert_id)
    body = response.parsed_body
    assert_equal "anchored", body["status"]
    assert_equal "https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069/messages/4",
                 body.dig("hcs", "mirror_url")
    assert_includes body.dig("hcs", "hashscan_url"), "topic/0.0.9585069"
  end

  test "unknown cert_id is 404" do
    get api_v1_certificate_url("pw-999999")
    assert_response :not_found
  end
end
