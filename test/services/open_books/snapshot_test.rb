require "test_helper"
require "webmock/minitest"

class OpenBooks::SnapshotTest < ActiveSupport::TestCase
  TOPIC = "0.0.9585069"
  MIRROR = "https://testnet.mirrornode.hedera.com"

  setup do
    @old_topic = ENV["HEDERA_HCS_TOPIC_ID"]
    ENV["HEDERA_HCS_TOPIC_ID"] = TOPIC
    Rails.cache.clear
    model = Model3d.create!(
      designer: designers(:one), title: "Open books", slug: "open-books-#{SecureRandom.hex(4)}"
    )
    offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    @purchase = Purchase.create!(
      license_offer: offer, status: "verified", replay_key: SecureRandom.hex(32),
      asset: "0.0.429274", amount_base_units: "250000",
      payment_tx_id: "0.0.7162784@1784449762.916833016"
    )
    @purchase.transition_to!(:settled)
    @license = License.allocate!(@purchase)
    @license.update!(hcs_topic_id: TOPIC, hcs_sequence_number: 50)
  end

  teardown do
    ENV["HEDERA_HCS_TOPIC_ID"] = @old_topic
    Rails.cache.clear
  end

  test "separates mirror certificate facts from balanced per-asset revenue books" do
    stub_latest_message

    snapshot = OpenBooks::Snapshot.call

    assert_equal "hedera:testnet", snapshot[:network]
    assert_equal({ designer_bps: 9000, platform_bps: 1000 }, snapshot[:split])
    assert_equal [ "ok", 50, 1, 49 ],
      snapshot[:hcs].values_at(:status, :message_count, :local_anchored_licenses, :count_difference)
    assert_includes snapshot[:hcs][:latest_message_url], "/messages/50"

    usdc = snapshot.dig(:ledger, :assets).sole
    assert_equal [ "0.0.429274", "USDC", 6 ], usdc.values_at(:asset, :symbol, :decimals)
    assert_equal [ 250_000, 225_000, 25_000, 0, 250_000 ], usdc.values_at(
      :gross_settled_base_units, :designer_share_base_units, :platform_fee_base_units,
      :refunded_base_units, :net_after_refunds_base_units
    )
    proof = snapshot[:recent_settlement_proofs].sole
    assert_equal 250_000, proof[:gross_base_units]
    assert_includes proof[:mirror_url], "/transactions/0.0.7162784-1784449762-916833016"
  end

  test "mirror failure is labeled unavailable without hiding the local ledger" do
    stub_request(:get, latest_query).to_timeout

    snapshot = OpenBooks::Snapshot.call

    assert_equal [ "unavailable", nil ], snapshot[:hcs].values_at(:status, :message_count)
    assert_equal 1, snapshot.dig(:ledger, :settlement_count)
    assert_equal 250_000, snapshot.dig(:ledger, :assets, 0, :gross_settled_base_units)
  end

  private

  def stub_latest_message
    certificate = { v: 1, cert_id: "pw-000058" }
    stub_request(:get, latest_query).to_return(
      body: {
        messages: [ {
          topic_id: TOPIC, sequence_number: 50,
          consensus_timestamp: "1784449779.736670002",
          message: Base64.strict_encode64(JSON.generate(certificate))
        } ]
      }.to_json,
      headers: { "content-type" => "application/json" }
    )
  end

  def latest_query
    "#{MIRROR}/api/v1/topics/#{TOPIC}/messages?limit=1&order=desc"
  end
end
