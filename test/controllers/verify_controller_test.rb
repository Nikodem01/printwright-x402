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
  def commitment_message(cert = @cert)
    Base64.strict_encode64(JSON.generate(Certificates::Commitment.envelope(cert, @license.cert_salt)))
  end

  test "revealed cert that hashes to the on-chain commitment renders settled" do
    anchor!
    stub_mirror({ message: commitment_message, consensus_timestamp: "1784141018.086938437" })
    get verify_path(@license.verify_slug)
    assert_response :success
    assert_select ".banner-ok .st-settled", text: /Verified on Hedera/
    assert_select ".cert-facts dt", text: "Commitment"
    assert_select ".cert-facts dd.chain", text: /1784141018\.086938437/
    assert_select ".cert-facts dd.mono", text: /Personal #1 · unlimited personal, non-commercial prints/
    assert_select ".evidence-footer a", minimum: 3
    assert_select 'meta[property="og:image"][content$="/share-card"]'
  end

  test "unanchored cert shows minting with auto-refresh" do
    get verify_path(@license.verify_slug)
    assert_response :success
    assert_select ".banner-pending", text: /Minting/
    assert_select 'meta[http-equiv="refresh"]', count: 1
  end

  test "personal certificate says the grant covers unlimited personal prints" do
    get verify_certificate_path(@license.verify_slug)

    assert_response :success
    assert_match "personal license <strong>##{@license.serial}</strong>", response.body
    assert_match "unlimited physical prints for personal, non-commercial use", response.body
    assert_no_match(/unit <strong>##{@license.serial}<\/strong> of/, response.body)
  end

  test "anchored but mirror 404 still shows minting (propagation)" do
    anchor!
    stub_mirror({ error: "not found" }, status: 404)
    get verify_path(@license.verify_slug)
    assert_select ".banner-pending"
  end

  test "revealed cert that does not hash to the commitment renders mismatch" do
    anchor!
    # on-chain commits to a different cert than the marketplace copy we reveal
    stub_mirror({ message: commitment_message(@cert.merge("unit_serial" => 999)), consensus_timestamp: "1.2" })
    get verify_path(@license.verify_slug)
    assert_select ".banner-bad", text: /Mismatch/
    assert_select "h3", text: /Recorded commitment vs the revealed certificate/
  end

  test "legacy full-cert on-chain message still verifies field-by-field" do
    anchor!
    stub_mirror({ message: Base64.strict_encode64(JSON.generate(@cert)), consensus_timestamp: "1.2" })
    get verify_path(@license.verify_slug)
    assert_select ".banner-ok"
  end

  test "unknown cert id is 404" do
    get verify_path("pw-999999")
    assert_response :not_found
    assert_select ".banner-bad", text: /not found/i
  end

  # The licence text tells buyers to keep their cert_id, and the receipt shows
  # it next to the verify link, so pasting the id into /verify is the mistake
  # the product invites. Telling them to "check the id on your receipt" when the
  # id came from the receipt sends them looking for a mistake they did not make.
  test "a cert_id pasted into verify explains that the link carries a different token" do
    get verify_path(@license.cert_id)

    assert_response :not_found
    assert_select ".banner-bad", text: /not found/i
    assert_match "is a certificate id, not a verify token", response.body
    assert_match "verify link on your receipt", response.body
    assert_match "/api/v1/certificates/#{@license.cert_id}", response.body
    assert_no_match(/Check the id on your receipt/, response.body)
  end

  test "the cert_id explanation is by shape, so it does not disclose which ids exist" do
    unissued = "pw-#{SecureRandom.hex(12)}"
    assert_nil License.find_by(cert_id: unissued)

    get verify_path(unissued)

    assert_response :not_found
    assert_match "is a certificate id, not a verify token", response.body
  end

  test "a sandbox cert_id is recognised too" do
    get verify_path("sandbox-pw-#{SecureRandom.hex(12)}")

    assert_response :not_found
    assert_match "is a certificate id, not a verify token", response.body
  end

  test "a token that is not cert_id-shaped keeps the plain not-found copy" do
    get verify_path("totally-unknown-token")

    assert_response :not_found
    assert_match "No certificate with id", response.body
    assert_no_match(/is a certificate id, not a verify token/, response.body)
  end

  test "certificate social metadata escapes a hostile model title" do
    @license.purchase.model3d.update!(title: 'Part"><script>alert(1)</script>')

    get verify_path(@license.verify_slug)

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
    get verify_path(real.verify_slug)
    assert_select ".banner-ok"
  ensure
    WebMock.disable_net_connect!(allow_localhost: true)
  end
end
