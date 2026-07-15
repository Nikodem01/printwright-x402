require "test_helper"
require "webmock/minitest"

class CertMintJobTest < ActiveJob::TestCase
  SIDECAR = "http://localhost:4021".freeze

  setup do
    ENV["SIDECAR_TOKEN"] = "test-sidecar-token"
    ENV["HEDERA_SIDECAR_URL"] = SIDECAR
    model = Model3d.create!(
      designer: designers(:one), title: "C", slug: "c-#{SecureRandom.hex(4)}",
      file_hash: "sha256:abc", status: "published"
    )
    designers(:one).update!(hedera_account_id: "0.0.777")
    offer = model.license_offers.create!(kind: "personal", price_cents: 250, terms_md: "T.")
    purchase = Purchase.create!(
      license_offer: offer, status: "settled", replay_key: SecureRandom.hex(32),
      buyer_hint: "0.0.9067781", payment_tx_id: "0.0.7162784@111.222"
    )
    @license = License.allocate!(purchase)
    purchase.transition_to!(:delivered)
  end

  test "builds the frozen v1 cert schema, compact and under the HCS limit" do
    cert = Certificates::Builder.call(@license)
    assert_equal %w[v cert_id model_id model_hash designer license_type unit_serial
                    buyer_hint payment_tx issued_at terms_hash], cert.keys
    assert_equal [ 1, @license.cert_id, "0.0.777", "personal", 1, "0.0.9067781", "0.0.7162784@111.222" ],
                 cert.values_at("v", "cert_id", "designer", "license_type", "unit_serial", "buyer_hint", "payment_tx")
    assert_operator JSON.generate(cert).bytesize, :<, 1024
  end

  test "successful mint stores cert_json and backfills topic + sequence" do
    stub_request(:post, "#{SIDECAR}/submit-cert")
      .with(headers: { "Authorization" => "Bearer test-sidecar-token" })
      .to_return(body: JSON.generate(topicId: "0.0.9585069", sequenceNumber: 7, transactionId: "0.0.1@2.3"),
                 headers: { "content-type" => "application/json" })

    CertMintJob.perform_now(@license.id)
    @license.reload
    assert @license.anchored?
    assert_equal [ "0.0.9585069", 7 ], [ @license.hcs_topic_id, @license.hcs_sequence_number ]
    assert_equal @license.cert_id, @license.cert_json["cert_id"]

    assert_requested(:post, "#{SIDECAR}/submit-cert") do |req|
      JSON.parse(req.body)["cert"] == @license.cert_json
    end
  end

  test "sidecar down: job retries, license stays unanchored, cert_json preserved" do
    stub_request(:post, "#{SIDECAR}/submit-cert").to_timeout

    assert_enqueued_with(job: CertMintJob) do # retry_on re-enqueues instead of raising
      CertMintJob.perform_now(@license.id)
    end
    @license.reload
    assert_not @license.anchored?
    assert @license.cert_json.present?, "cert must be built even when submission fails"

    # sidecar comes back: same job id backfills, cert bytes unchanged
    built = @license.cert_json
    stub_request(:post, "#{SIDECAR}/submit-cert")
      .to_return(body: JSON.generate(topicId: "0.0.9585069", sequenceNumber: 8, transactionId: "0.0.1@4.5"),
                 headers: { "content-type" => "application/json" })
    CertMintJob.perform_now(@license.id)
    assert @license.reload.anchored?
    assert_equal built, @license.cert_json
  end

  test "anchored license is a no-op (idempotent)" do
    @license.update!(hcs_topic_id: "0.0.9585069", hcs_sequence_number: 3, cert_json: { "v" => 1 })
    CertMintJob.perform_now(@license.id)
    assert_not_requested :post, "#{SIDECAR}/submit-cert"
  end

  test "sidecar rejection (non-200) does not retry forever" do
    stub_request(:post, "#{SIDECAR}/submit-cert")
      .to_return(status: 422, body: '{"error":"cert_too_large"}')
    assert_raises(SidecarClient::Rejected) { CertMintJob.perform_now(@license.id) }
    assert_not @license.reload.anchored?
  end
end
