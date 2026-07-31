require "test_helper"

class Certificates::BundleTest < ActiveSupport::TestCase
  setup do
    model = Model3d.create!(
      designer: designers(:one), title: "B", slug: "b-#{SecureRandom.hex(4)}",
      file_hash: "sha256:#{'a' * 64}", status: "published"
    )
    offer = model.license_offers.create!(kind: "personal", price_cents: 250, terms_md: "Bundle terms.")
    purchase = Purchase.create!(
      license_offer: offer, status: "settled", replay_key: SecureRandom.hex(32),
      buyer_hint: "0.0.9613501", payment_tx_id: "0.0.7@1.2"
    )
    @license = License.allocate!(purchase)
    @license.update!(cert_json: Certificates::Builder.call(@license))
  end

  test "bundle is a self-contained reveal whose commitment recomputes from cert + nonce" do
    bundle = Certificates::Bundle.for(@license)
    # proof_version mirrors the certificate schema version it reveals.
    assert_equal @license.cert_json["v"], bundle["proof_version"]
    assert_equal 2, bundle["proof_version"]
    assert_equal "sha256-jcs-v1", bundle["algorithm"]
    assert_equal @license.cert_json, bundle["certificate"]
    assert_equal @license.cert_salt, bundle["blinding_nonce"]
    # anyone can recompute the commitment from the revealed preimage
    recomputed = Certificates::Commitment.digest(bundle["certificate"], bundle["blinding_nonce"])
    assert_equal recomputed, bundle["commitment"]
  end

  test "bundle carries the exact licensed terms bytes, not just a hash" do
    offer = @license.purchase.license_offer
    terms = Certificates::Bundle.for(@license)["terms"]
    assert_equal offer.terms_hash, terms["hash"]
    assert_equal offer.terms_text, terms["text"] # the full licensed document, not a pointer
    assert terms["text"].present?
  end

  test "revealed terms are the ones the certificate committed to, not the offer's newest" do
    model = Model3d.create!(designer: designers(:one), title: "V", slug: "v-#{SecureRandom.hex(4)}",
      file_hash: "sha256:#{'c' * 64}", status: "published")
    offer = model.license_offers.create!(kind: "personal", price_cents: 250, terms_version: "v1")
    purchase = Purchase.create!(license_offer: offer, status: "settled",
      replay_key: SecureRandom.hex(32), payment_tx_id: "0.0.7@2.#{SecureRandom.hex(4)}")
    license = License.allocate!(purchase)
    license.update!(cert_json: Certificates::Builder.call(license))
    sold_under = license.cert_json.fetch("terms_hash")

    # The designer's offer later moves to the current published version; the
    # license already sold keeps the grant it was sold under.
    offer.update_columns(terms_version: Licensing::Documents::CURRENT_VERSION,
      terms_hash: Licensing::Documents.hash(Licensing::Documents::CURRENT_VERSION, "personal"))

    terms = Certificates::Bundle.for(license.reload)["terms"]
    assert_equal "v1", terms["version"]
    assert_equal sold_under, terms["hash"]
    assert_equal "sha256:#{Digest::SHA256.hexdigest(terms['text'])}", terms["hash"]
  end

  test "hedera block is pending before anchor and carries mirror coordinates after" do
    assert_equal "minting", Certificates::Bundle.for(@license).dig("hedera", "status")

    @license.update!(hcs_topic_id: "0.0.9585069", hcs_sequence_number: 57)
    hedera = Certificates::Bundle.for(@license)["hedera"]
    assert_equal [ "testnet", "0.0.9585069", 57 ],
                 hedera.values_at("network", "topic_id", "sequence_number")
    assert_includes hedera["mirror_url"], "/topics/0.0.9585069/messages/57"
    refute hedera.key?("hashscan_url")
  end
end
