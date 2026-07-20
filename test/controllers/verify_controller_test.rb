require "test_helper"
require "webmock/minitest"

class VerifyControllerTest < ActionDispatch::IntegrationTest
  MIRROR = "https://testnet.mirrornode.hedera.com".freeze

  setup do
    model = Model3d.create!(
      designer: designers(:one), title: "V", slug: "v-#{SecureRandom.hex(4)}",
      file_hash: "sha256:abc", status: "published"
    )
    offer = model.license_offers.create!(kind: "personal", price_cents: 250, terms_md: "T.")
    purchase = Purchase.create!(
      license_offer: offer, status: "delivered", replay_key: SecureRandom.hex(32),
      buyer_hint: "0.0.9067781", payment_tx_id: "0.0.7162784@111.222"
    )
    @license = License.allocate!(purchase)
    @cert = Certificates::Builder.call(@license)
    @license.update!(cert_json: @cert)
  end

  def anchor!(sequence: 9)
    @license.update!(hcs_topic_id: "0.0.9585069", hcs_sequence_number: sequence)
  end

  def stub_mirror(body, status: 200)
    stub_request(:get, "#{MIRROR}/api/v1/topics/0.0.9585069/messages/9")
      .to_return(status: status, body: JSON.generate(body), headers: { "content-type" => "application/json" })
  end

  # Status is shape-first and never green: green marks issuance only, so a
  # settled certificate takes the ink state mark, and the accent is spent on
  # the on-chain facts instead.
  test "anchored matching cert renders the settled state with consensus time" do
    anchor!
    stub_mirror({ message: Base64.strict_encode64(JSON.generate(@cert)), consensus_timestamp: "1784141018.086938437" })
    get verify_path(@license.cert_id)
    assert_response :success
    assert_select ".banner-ok .st-settled", text: /Verified on Hedera/
    assert_select ".cert-facts dd.chain", text: /1784141018\.086938437/
    assert_select ".cert-facts dd.mono", text: /1 of/
    assert_select ".evidence-footer a", minimum: 3
    assert_select 'meta[property="og:image"][content$="/share-card"]'
  end

  test "unanchored cert shows minting with auto-refresh" do
    get verify_path(@license.cert_id)
    assert_response :success
    assert_select ".banner-pending", text: /Minting/
    assert_select 'meta[http-equiv="refresh"]', count: 1
  end

  test "anchored but mirror 404 still shows minting (propagation)" do
    anchor!
    stub_mirror({ error: "not found" }, status: 404)
    get verify_path(@license.cert_id)
    assert_select ".banner-pending"
  end

  test "tampered on-chain copy renders mismatch with both copies" do
    anchor!
    stub_mirror({ message: Base64.strict_encode64(JSON.generate(@cert.merge("unit_serial" => 999))),
                  consensus_timestamp: "1.2" })
    get verify_path(@license.cert_id)
    assert_select ".banner-bad", text: /Mismatch/
    assert_select ".mismatch-row", minimum: 1
  end

  test "unknown cert id is 404" do
    get verify_path("pw-999999")
    assert_response :not_found
    assert_select ".banner-bad", text: /not found/i
  end

  test "certificate social metadata escapes a hostile model title" do
    @license.purchase.model3d.update!(title: 'Part"><script>alert(1)</script>')

    get verify_path(@license.cert_id)

    assert_response :success
    assert_select 'meta[property="og:image"][content$="/share-card"]'
    assert_select 'meta[property="og:image:alt"][content=?]',
      "Printwright license certificate #{@license.cert_id} for Part\"><script>alert(1)</script>"
    assert_select "script", { text: /alert\(1\)/, count: 0 }
    assert_no_match(/<script>alert\(1\)<\/script>/, response.body)
  end

  test "LIVE: real cert verifies against the real mirror node" do
    skip "set LIVE=1 to run against the live mirror node" unless ENV["LIVE"] == "1"
    WebMock.allow_net_connect!
    real = License.find_by(cert_id: "pw-000002")
    skip "no real cert in this database" unless real
    get verify_path(real.cert_id)
    assert_select ".banner-ok"
  ensure
    WebMock.disable_net_connect!(allow_localhost: true)
  end
end
