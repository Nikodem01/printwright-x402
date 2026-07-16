require "test_helper"
require "webmock/minitest"

class Ledger::PayoutRunnerTest < ActiveSupport::TestCase
  SIDECAR = "http://localhost:4021".freeze

  setup do
    ENV["X402_PAY_TO"] = "0.0.9584959"
    ENV["SIDECAR_TOKEN"] = "test-token"
    @paid_designer = designers(:one)
    @paid_designer.update!(hedera_account_id: "0.0.9604186")
    @paid_designer.update!(payout_account_verified_at: Time.current)

    @unverified = Designer.create!(
      email_address: "custody@example.com", password: "password",
      display_name: "Custody Case", hedera_account_id: "0.0.5005"
    )

    @owed_a = owed_purchase(@paid_designer, "250000")  # share 225000
    @owed_b = owed_purchase(@paid_designer, "90000")   # share 81000
    @owed_unverified = owed_purchase(@unverified, "100000")
  end

  test "dry run reports batched totals per designer without paying" do
    results = Ledger::PayoutRunner.call(dry_run: true)

    assert_equal 1, results.size
    assert_nil results.first.tx_id
    assert_equal [ { accountId: "0.0.9604186", amount: "306000" } ], results.first.transfers
    assert_empty LedgerEntry.where(entry_kind: "designer_payout")
  end

  test "payout pays verified designers, records entries, and is idempotent" do
    stub = stub_request(:post, "#{SIDECAR}/payout")
      .with(body: hash_including("tokenId" => "0.0.429274"))
      .to_return(body: { transactionId: "0.0.9067781@777.888" }.to_json,
                 headers: { "content-type" => "application/json" })

    results = Ledger::PayoutRunner.call
    assert_equal "0.0.9067781@777.888", results.first.tx_id

    payouts = LedgerEntry.where(entry_kind: "designer_payout")
    assert_equal [ @owed_a.id, @owed_b.id ].sort, payouts.pluck(:purchase_id).sort
    assert payouts.all? { |e| e.tx_id == "0.0.9067781@777.888" && e.held_by == "designer" }
    assert_equal 306_000, payouts.sum { |e| e.amount_base_units }

    # the unverified designer's share stays owed
    assert_equal [ @owed_unverified.id ], LedgerEntry.owed.pluck(:purchase_id)

    # second run finds nothing for the paid designer
    assert_empty Ledger::PayoutRunner.call
    assert_requested stub, times: 1
  end

  test "direct-paid purchases are never owed" do
    direct = Purchase.create!(
      license_offer: @owed_a.license_offer, status: "verified",
      asset: "0.0.429274", amount_base_units: "100000",
      replay_key: SecureRandom.hex(32),
      requirements_json: { "payTo" => "0.0.9604186" }
    )
    direct.transition_to!(:settled)

    assert_not_includes LedgerEntry.owed.pluck(:purchase_id), direct.id
  end

  private

  def owed_purchase(designer, amount)
    model = Model3d.create!(
      designer: designer, title: "Payout", slug: "payout-#{SecureRandom.hex(4)}"
    )
    offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    purchase = Purchase.create!(
      license_offer: offer, status: "verified",
      asset: "0.0.429274", amount_base_units: amount,
      replay_key: SecureRandom.hex(32),
      requirements_json: { "payTo" => "0.0.9584959" }
    )
    purchase.transition_to!(:settled)
    purchase
  end
end
