require "test_helper"
require "webmock/minitest"

# The job is a thin wrapper over Ledger::PayoutRunner scoped to one checkout;
# these cover the behavior the checkout enqueue relies on. perform_enqueued_jobs
# + perform_later (not perform_now) so the job's retry_on is exercised the way
# the queue would run it (per the Rails testing guide).
class DesignerPayoutJobTest < ActiveJob::TestCase
  SIDECAR = "http://localhost:4021".freeze

  setup do
    ENV["X402_PAY_TO"] = "0.0.9584959"
    ENV["SIDECAR_TOKEN"] = "test-token"
    @designer = designers(:one)
    @designer.update!(hedera_account_id: "0.0.9604186") # separate updates: setting the
    @designer.update!(payout_account_verified_at: Time.current) # account id resets verification
  end

  test "pays a verified designer their share for a single-purchase checkout" do
    stub = stub_payout("0.0.9067781@1.1")
    purchase = settled_purchase(@designer, "250000") # 90% share = 225000

    perform_enqueued_jobs do
      DesignerPayoutJob.perform_later(purchase_ids: [ purchase.id ], ref: "purchase-#{purchase.id}")
    end

    payout = LedgerEntry.where(entry_kind: "designer_payout", purchase: purchase).sole
    assert_equal 225_000, payout.amount_base_units
    assert_equal "0.0.9067781@1.1", payout.tx_id
    assert_not_includes LedgerEntry.owed.pluck(:purchase_id), purchase.id
    assert_requested stub, times: 1
  end

  test "a multi-model checkout from one designer is a single summed payment" do
    stub_payout("0.0.9067781@2.2")
    a = settled_purchase(@designer, "250000") # share 225000
    b = settled_purchase(@designer, "90000")  # share  81000

    perform_enqueued_jobs do
      DesignerPayoutJob.perform_later(purchase_ids: [ a.id, b.id ], ref: "batch-1")
    end

    # one /payout call crediting the summed share in a single transfer line...
    assert_requested :post, "#{SIDECAR}/payout", times: 1,
      body: hash_including("transfers" => [ { "accountId" => "0.0.9604186", "amount" => "306000" } ])
    # ...but a designer_payout row per purchase, sharing the one tx id
    rows = LedgerEntry.where(entry_kind: "designer_payout", purchase: [ a, b ])
    assert_equal [ a.id, b.id ].sort, rows.pluck(:purchase_id).sort
    assert(rows.all? { |row| row.tx_id == "0.0.9067781@2.2" })
  end

  test "an unverified designer is not paid; the share stays owed" do
    stub = stub_request(:post, "#{SIDECAR}/payout")
    unverified = Designer.create!(
      email_address: "custody@example.com", password: "password",
      display_name: "Custody Case", hedera_account_id: "0.0.5005"
    )
    purchase = settled_purchase(unverified, "100000")

    perform_enqueued_jobs do
      DesignerPayoutJob.perform_later(purchase_ids: [ purchase.id ], ref: "purchase-#{purchase.id}")
    end

    assert_not_requested stub
    assert_includes LedgerEntry.owed.pluck(:purchase_id), purchase.id
  end

  test "re-running the same checkout does not double-pay" do
    stub_payout("0.0.9067781@3.3")
    purchase = settled_purchase(@designer, "250000")
    args = { purchase_ids: [ purchase.id ], ref: "purchase-#{purchase.id}" }

    perform_enqueued_jobs { DesignerPayoutJob.perform_later(**args) }
    perform_enqueued_jobs { DesignerPayoutJob.perform_later(**args) }

    assert_requested :post, "#{SIDECAR}/payout", times: 1
    assert_equal 1, LedgerEntry.where(entry_kind: "designer_payout", purchase: purchase).count
  end

  private

  def stub_payout(tx_id)
    stub_request(:post, "#{SIDECAR}/payout")
      .to_return(body: { transactionId: tx_id }.to_json,
                 headers: { "content-type" => "application/json" })
  end

  def settled_purchase(designer, amount)
    model = Model3d.create!(designer: designer, title: "Payout", slug: "payout-#{SecureRandom.hex(4)}")
    offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    purchase = Purchase.create!(
      license_offer: offer, status: "verified", asset: "0.0.429274",
      amount_base_units: amount, replay_key: SecureRandom.hex(32),
      requirements_json: { "payTo" => "0.0.9584959" }
    )
    purchase.transition_to!(:settled)
    purchase
  end
end
