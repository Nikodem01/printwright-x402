require "test_helper"
require "webmock/minitest"

class Purchases::ReaperTest < ActiveSupport::TestCase
  MIRROR = "https://testnet.mirrornode.hedera.com".freeze

  setup do
    ENV["X402_PAY_TO"] = "0.0.9584959"
    model = Model3d.create!(designer: designers(:one), title: "Reap", slug: "reap-#{SecureRandom.hex(4)}")
    @offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    stub_request(:get, "#{MIRROR}/api/v1/network/nodes?limit=1").to_return(status: 200, body: "{}")
  end

  def stale_purchase(status:)
    Purchase.create!(
      license_offer: @offer, status: status,
      asset: "0.0.429274", amount_base_units: "250000",
      buyer_hint: "0.0.9067781", replay_key: SecureRandom.hex(32),
      requirements_json: { "payTo" => "0.0.9584959", "amount" => "250000", "asset" => "0.0.429274" },
      created_at: 2.hours.ago
    )
  end

  def stub_mirror_transactions(transactions)
    stub_request(:get, %r{#{MIRROR}/api/v1/transactions\?account\.id=0\.0\.9584959})
      .to_return(body: { transactions: transactions }.to_json,
                 headers: { "content-type" => "application/json" })
  end

  test "money moved: rolls forward to delivered with a license" do
    purchase = stale_purchase(status: "verified")
    stub_mirror_transactions([ {
      "result" => "SUCCESS", "transaction_id" => "0.0.9067781-111-222",
      "token_transfers" => [ { "token_id" => "0.0.429274", "account" => "0.0.9584959", "amount" => 250000 } ]
    } ])

    results = Purchases::Reaper.call
    assert_equal [ "rolled_forward" ], results.map(&:action)
    assert purchase.reload.delivered?
    assert purchase.license.present?
    assert_equal "0.0.9067781@111.222", purchase.payment_tx_id
  end

  test "no money moved: fails the purchase and frees capacity" do
    pending = stale_purchase(status: "pending")
    verified = stale_purchase(status: "verified")
    stub_mirror_transactions([])

    results = Purchases::Reaper.call
    assert_equal %w[failed_stale failed_stale], results.map(&:action)
    assert pending.reload.failed_verification?
    assert verified.reload.failed_settlement?
    assert_equal "reaped_stale", pending.error_reason
    assert_not @offer.reload.sold_out?, "failed purchases must not hold capacity"
  end

  test "mirror unreachable: skips rather than failing blind" do
    stale_purchase(status: "pending")
    stub_request(:get, %r{#{MIRROR}/api/v1/transactions}).to_timeout
    stub_request(:get, "#{MIRROR}/api/v1/network/nodes?limit=1").to_timeout

    results = Purchases::Reaper.call
    assert_equal [ "skipped_mirror_unreachable" ], results.map(&:action)
    assert Purchase.sole.pending?
  end

  test "fresh purchases are left alone" do
    Purchase.create!(
      license_offer: @offer, status: "pending",
      asset: "0.0.429274", amount_base_units: "250000",
      replay_key: SecureRandom.hex(32)
    )
    assert_empty Purchases::Reaper.call
  end
end
