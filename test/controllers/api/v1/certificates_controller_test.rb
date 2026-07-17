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

class CertificateNftBlockTest < ActionDispatch::IntegrationTest
  test "anchored cert with an NFT exposes the claim state, refreshing pending from the mirror" do
    require "webmock/minitest"
    model = Model3d.create!(designer: designers(:one), title: "N", slug: "nftapi-#{SecureRandom.hex(4)}")
    offer = model.license_offers.create!(kind: "personal", price_cents: 100)
    purchase = Purchase.create!(license_offer: offer, status: "settled", buyer_hint: "0.0.9613664",
      asset: "0.0.429274", amount_base_units: "100000", payment_tx_id: "0.0.7@9.9", replay_key: SecureRandom.hex(32))
    license = License.allocate!(purchase)
    license.update!(cert_json: { "v" => 1 }, hcs_topic_id: "0.0.9585069", hcs_sequence_number: 9,
      nft_token_id: "0.0.9613489", nft_serial: 3, nft_claim_state: "pending", nft_airdrop_tx_id: "0.0.1@1.1")

    WebMock.stub_request(:get, %r{mirrornode\.hedera\.com/api/v1/accounts/0\.0\.9613664/nfts})
      .to_return(body: { nfts: [ { serial_number: 3 } ] }.to_json, headers: { "content-type" => "application/json" })

    get api_v1_certificate_path(license.cert_id)
    nft = response.parsed_body["nft"]
    assert_equal [ "0.0.9613489", 3, "claimed" ], [ nft["token_id"], nft["serial"], nft["claim_state"] ]
    assert_equal "claimed", license.reload.nft_claim_state
    assert_includes nft["hashscan_url"], "/token/0.0.9613489/3"
  end

  test "certs without an NFT have a null nft block" do
    model = Model3d.create!(designer: designers(:one), title: "NoN", slug: "non-#{SecureRandom.hex(4)}")
    offer = model.license_offers.create!(kind: "personal", price_cents: 100)
    purchase = Purchase.create!(license_offer: offer, status: "settled", replay_key: SecureRandom.hex(32))
    license = License.allocate!(purchase)
    license.update!(cert_json: { "v" => 1 })

    get api_v1_certificate_path(license.cert_id)
    assert_nil response.parsed_body["nft"]
  end
end
