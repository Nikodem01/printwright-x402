require "test_helper"
require "webmock/minitest"

class Ledger::PayoutRunnerTest < ActiveSupport::TestCase
  SIDECAR = "http://localhost:4021".freeze

  setup do
    set_printwright(sidecar_token: "test-token")
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
    assert_empty PayoutAttempt.all
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
    attempts = PayoutAttempt.where(purchase: [ @owed_a, @owed_b ])
    assert_equal %w[succeeded succeeded], attempts.order(:purchase_id).pluck(:status)
    assert attempts.all? { |attempt| attempt.tx_id == "0.0.9067781@777.888" }

    # the unverified designer's share stays owed
    assert_equal [ @owed_unverified.id ], LedgerEntry.owed.pluck(:purchase_id)

    # second run finds nothing for the paid designer
    assert_empty Ledger::PayoutRunner.call
    assert_requested stub, times: 1
  end

  test "purchase_ids scopes the run to one checkout and the memo carries the ref" do
    stub = stub_request(:post, "#{SIDECAR}/payout")
      .with(body: hash_including("memo" => "printwright payout batch-7"))
      .to_return(body: { transactionId: "0.0.9067781@9.9" }.to_json,
                 headers: { "content-type" => "application/json" })

    Ledger::PayoutRunner.call(purchase_ids: [ @owed_a.id ], ref: "batch-7")

    # only the scoped purchase was paid; the sibling owed share is untouched
    assert_equal [ @owed_a.id ], LedgerEntry.where(entry_kind: "designer_payout").pluck(:purchase_id)
    assert_includes LedgerEntry.owed.pluck(:purchase_id), @owed_b.id
    assert_requested stub, times: 1
  end

  test "a replacement safety hold continues paying only the old active destination" do
    @paid_designer.update!(payout_account_control_verified_at: Time.current,
      payout_pending_account_id: "0.0.7007", payout_proof_verified_at: Time.current,
      payout_hold_until: 24.hours.from_now)

    results = Ledger::PayoutRunner.call(dry_run: true)

    assert_equal [ { accountId: "0.0.9604186", amount: "306000" } ], results.first.transfers
    assert_equal "0.0.7007", @paid_designer.reload.payout_pending_account_id
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

  test "a pre-submit outage records a safe failed attempt for an operator run" do
    stub_request(:post, "#{SIDECAR}/payout")
      .to_return(status: 503, body: { error: "treasury_not_configured" }.to_json,
                 headers: { "content-type" => "application/json" })

    assert_raises(SidecarClient::Unavailable) do
      Ledger::PayoutRunner.call(ref: "operator-safe-failure")
    end

    attempts = PayoutAttempt.where(designer: @paid_designer)
    assert_equal 2, attempts.count
    assert attempts.all?(&:retryable?)
    assert_equal [ "service_unavailable" ], attempts.distinct.pluck(:last_error_code)
    assert_equal [ @owed_a.id, @owed_b.id ].sort,
      LedgerEntry.owed.where(designer: @paid_designer).pluck(:purchase_id).sort
  end

  test "an ambiguous response is never retried by a later sweep" do
    ambiguous = owed_purchase(@paid_designer, "100000", asset: "0.0.0")
    stub_request(:post, "#{SIDECAR}/payout")
      .with(body: hash_including("tokenId" => "0.0.429274"))
      .to_return(body: { transactionId: "0.0.9067781@5.5" }.to_json,
                 headers: { "content-type" => "application/json" })
    ambiguous_stub = stub_request(:post, "#{SIDECAR}/payout")
      .with(body: hash_including("tokenId" => "0.0.0"))
      .to_return(status: 502, body: { error: "hedera_error" }.to_json,
                 headers: { "content-type" => "application/json" })

    assert_raises(SidecarClient::Ambiguous) do
      Ledger::PayoutRunner.call(ref: "multi-asset-ambiguous")
    end

    assert_equal [ @owed_a.id, @owed_b.id ].sort,
      LedgerEntry.where(entry_kind: "designer_payout").pluck(:purchase_id).sort
    assert_not_includes LedgerEntry.owed.pluck(:purchase_id), @owed_a.id
    issue = PayoutAttempt.find_by!(purchase: ambiguous)
    assert_equal [ "reconciliation_required", "ambiguous_result" ],
      issue.values_at("status", "last_error_code")
    assert_not issue.retryable?

    assert_empty Ledger::PayoutRunner.call(ref: "later-sweep")
    assert_requested ambiguous_stub, times: 1
    assert_includes LedgerEntry.owed.pluck(:purchase_id), ambiguous.id
  end

  test "a completed run notifies the designer once with a safe payload, not per ledger row" do
    stub_request(:post, "#{SIDECAR}/payout")
      .to_return(body: { transactionId: "0.0.9067781@777.888" }.to_json,
                 headers: { "content-type" => "application/json" })

    Ledger::PayoutRunner.call(ref: "checkout-ref")

    notification = @paid_designer.seller_notifications.sole
    assert_equal "payout_completed", notification.kind
    assert_equal(
      { "asset" => "0.0.429274", "amount_base_units" => "306000",
        "tx_id" => "0.0.9067781@777.888", "ref" => "checkout-ref" },
      notification.payload
    )
  end

  test "a pre-submit outage on an operator run notifies the designer that the payout failed" do
    stub_request(:post, "#{SIDECAR}/payout")
      .to_return(status: 503, body: { error: "treasury_not_configured" }.to_json,
                 headers: { "content-type" => "application/json" })

    assert_raises(SidecarClient::Unavailable) do
      Ledger::PayoutRunner.call(ref: "operator-safe-failure")
    end

    notification = @paid_designer.seller_notifications.sole
    assert_equal "payout_failed", notification.kind
    assert_equal "service_unavailable", notification.payload["error_code"]
  end

  test "a retrying (non-terminal) outage does not yet notify the designer" do
    stub_request(:post, "#{SIDECAR}/payout")
      .to_return(status: 503, body: { error: "treasury_not_configured" }.to_json,
                 headers: { "content-type" => "application/json" })

    assert_raises(SidecarClient::Unavailable) do
      Ledger::PayoutRunner.call(ref: "auto-retry", automatic_retry: true)
    end

    assert_empty @paid_designer.seller_notifications
  end

  test "the payout itself succeeds even when notification creation raises" do
    stub_request(:post, "#{SIDECAR}/payout")
      .to_return(body: { transactionId: "0.0.9067781@777.888" }.to_json,
                 headers: { "content-type" => "application/json" })
    singleton = SellerNotification.singleton_class
    original = SellerNotification.method(:record!)
    singleton.define_method(:record!) { |**| raise "boom" }

    results = Ledger::PayoutRunner.call

    assert_equal "0.0.9067781@777.888", results.first.tx_id
    assert_equal %w[succeeded succeeded],
      PayoutAttempt.where(purchase: [ @owed_a, @owed_b ]).order(:purchase_id).pluck(:status)
    assert_empty SellerNotification.all
  ensure
    singleton&.define_method(:record!, original) if original
  end

  private

  def owed_purchase(designer, amount, asset: "0.0.429274")
    model = Model3d.create!(
      designer: designer, title: "Payout", slug: "payout-#{SecureRandom.hex(4)}"
    )
    offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    purchase = Purchase.create!(
      license_offer: offer, status: "verified",
      asset: asset, amount_base_units: amount,
      replay_key: SecureRandom.hex(32),
      requirements_json: { "payTo" => "0.0.9584959" }
    )
    purchase.transition_to!(:settled)
    purchase
  end
end
