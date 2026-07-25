require "application_system_test_case"
require "webmock/minitest"

# The public trust surface: every state the verify page can honestly claim,
# driven as pages (the mirror node is the stubbed source of truth).
class VerifyStatesTest < RackSystemTestCase
  MIRROR = "https://testnet.mirrornode.hedera.com".freeze

  setup do
    WebMock.disable_net_connect!(allow_localhost: true)
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

  test "unanchored cert shows the minting state with auto-refresh" do
    visit verify_path(@license.verify_slug)
    assert_selector ".banner-pending", text: /Minting/
    assert_selector 'meta[http-equiv="refresh"]', count: 1, visible: false
  end

  test "anchored matching cert shows the green verified banner" do
    anchor!
    stub_mirror(message: commitment_envelope, consensus_timestamp: "1784141018.086938437")
    visit verify_path(@license.verify_slug)
    assert_selector ".banner-ok", text: /Verified on Hedera/
    assert_text @license.cert_id
  end

  test "a certificate the on-chain commitment does not cover shows the mismatch banner" do
    anchor!
    # Same anchor, a certificate altered after it was committed: the reveal no
    # longer hashes to what the ledger holds.
    stub_mirror(message: commitment_envelope(@cert.merge("unit_serial" => 999)),
                consensus_timestamp: "1.2")
    visit verify_path(@license.verify_slug)
    assert_selector ".banner-bad", text: /Mismatch/
    assert_text "Recorded commitment"
  end

  test "unknown cert renders the honest not-found page" do
    visit verify_path("not-a-real-verify-token")
    assert_selector ".banner-bad", text: /not found/i
  end

  private

  SEQUENCE = 9

  def anchor!
    @license.update!(hcs_topic_id: "0.0.9585069", hcs_sequence_number: SEQUENCE)
  end

  # What the topic actually carries: the opaque envelope, nothing readable.
  def commitment_envelope(cert = @cert)
    Base64.strict_encode64(
      JSON.generate(Certificates::Commitment.envelope(cert, @license.cert_salt))
    )
  end

  def stub_mirror(**body)
    stub_request(:get, "#{MIRROR}/api/v1/topics/0.0.9585069/messages/#{SEQUENCE}")
      .to_return(body: JSON.generate(body), headers: { "content-type" => "application/json" })
  end
end
