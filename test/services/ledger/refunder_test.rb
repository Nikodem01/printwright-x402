require "test_helper"
require "webmock/minitest"

class Ledger::RefunderTest < ActiveSupport::TestCase
  SIDECAR = "http://localhost:4021".freeze

  setup do
    ENV["X402_PAY_TO"] = "0.0.9584959"
    ENV["SIDECAR_TOKEN"] = "test-token"
    model = Model3d.create!(designer: designers(:one), title: "R", slug: "refund-#{SecureRandom.hex(4)}")
    offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    @purchase = Purchase.create!(
      license_offer: offer, status: "verified", buyer_hint: "0.0.9067781",
      asset: "0.0.429274", amount_base_units: "250000",
      replay_key: SecureRandom.hex(32),
      requirements_json: { "payTo" => "0.0.9584959" }
    )
    @purchase.transition_to!(:settled)
  end

  test "refunds gross to the buyer, records the ledger row, clears owed" do
    stub = stub_request(:post, "#{SIDECAR}/payout")
      .with { |req|
        body = JSON.parse(req.body)
        body["transfers"] == [ { "accountId" => "0.0.9067781", "amount" => "250000" } ] &&
          body["memo"].start_with?("printwright refund #{@purchase.replay_key.first(32)}")
      }
      .to_return(body: { transactionId: "0.0.9067781@1.2" }.to_json,
                 headers: { "content-type" => "application/json" })

    tx = Ledger::Refunder.call(@purchase)

    assert_equal "0.0.9067781@1.2", tx
    assert @purchase.reload.refunded?
    assert_equal "0.0.9067781@1.2", @purchase.refund_tx_id
    refund = LedgerEntry.find_by!(purchase: @purchase, entry_kind: "refund")
    assert_equal 250_000, refund.amount_base_units
    assert_not_includes LedgerEntry.owed.pluck(:purchase_id), @purchase.id
    assert_requested stub, times: 1
  end

  test "refuses delivered, unknown-buyer, and paid-out purchases" do
    delivered = @purchase.dup.tap { |p| p.assign_attributes(status: "delivered", replay_key: SecureRandom.hex(32)); p.save! }
    assert_raises(Ledger::Refunder::NotRefundable) { Ledger::Refunder.call(delivered) }

    @purchase.update!(buyer_hint: "bearer")
    assert_raises(Ledger::Refunder::NotRefundable) { Ledger::Refunder.call(@purchase) }

    @purchase.update!(buyer_hint: "0.0.9067781")
    LedgerEntry.create!(purchase: @purchase, designer: designers(:one), entry_kind: "designer_payout",
      asset: "0.0.429274", amount_base_units: "225000", held_by: "designer", tx_id: "0.0.1@1")
    assert_raises(Ledger::Refunder::NotRefundable) { Ledger::Refunder.call(@purchase) }
    assert @purchase.reload.settled?, "a refused refund must change nothing"
  end

  test "refuses sandbox rows even if their state is settled" do
    @purchase.update!(sandbox: true, buyer_hint: "0.0.9067781")

    error = assert_raises(Ledger::Refunder::NotRefundable) { Ledger::Refunder.call(@purchase) }
    assert_match(/sandbox/, error.message)
    assert @purchase.reload.settled?
  end
end
