require "test_helper"

class Designer::PayoutAttemptsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ENV["X402_PAY_TO"] = "0.0.9584959"
    @designer = designers(:two)
    @designer.update!(hedera_account_id: "0.0.7007")
    @designer.update!(payout_account_verified_at: Time.current,
      payout_account_control_verified_at: Time.current)
    @purchase = delivered_purchase(@designer, buyer_hint: "private-buyer@example.com")
    @attempt = PayoutAttempt.create!(designer: @designer, purchase: @purchase,
      ref: "purchase-#{@purchase.id}", asset: @purchase.asset, status: "failed",
      attempt_count: 10, last_error_code: "service_unavailable",
      last_attempted_at: 2.minutes.ago)
    sign_in_as @designer
  end

  test "Payouts exposes a safe retry without buyer-private data" do
    get designer_payouts_path

    assert_response :success
    assert_select "#payout-attention", text: /Safe retry available.*0\.22 USDC.*1 sale.*10/m
    assert_select "form[action=?]", retry_designer_payout_attempt_path(@attempt)
    assert_no_match "private-buyer@example.com", response.body
    assert_no_match @purchase.replay_key, response.body
  end

  test "safe retry queues only the authenticated designer's still-owed shares" do
    sibling = delivered_purchase(@designer)
    PayoutAttempt.create!(designer: @designer, purchase: sibling,
      ref: @attempt.ref, asset: sibling.asset, status: "failed", attempt_count: 10,
      last_error_code: "service_unavailable", last_attempted_at: 2.minutes.ago)

    assert_enqueued_with(job: DesignerPayoutJob,
      args: [ { purchase_ids: [ @purchase.id, sibling.id ], ref: @attempt.ref } ]) do
      post retry_designer_payout_attempt_path(@attempt)
    end

    assert_redirected_to designer_payouts_path(anchor: "payout-attention")
    assert_equal [ "retrying" ],
      PayoutAttempt.where(purchase: [ @purchase, sibling ]).distinct.pluck(:status)
    assert_empty LedgerEntry.where(entry_kind: "designer_payout", purchase: [ @purchase, sibling ])
    assert_equal %w[delivered delivered], Purchase.where(id: [ @purchase.id, sibling.id ]).pluck(:status)
  end

  test "ambiguous and rejected transfer states cannot be retried through the seller UI" do
    @attempt.update!(status: "reconciliation_required", last_error_code: "ambiguous_result")

    get designer_payouts_path
    assert_select "#payout-attention", text: /needs reconciliation.*Do not retry/m
    assert_select "form[action=?]", retry_designer_payout_attempt_path(@attempt), count: 0

    assert_no_enqueued_jobs(only: DesignerPayoutJob) do
      post retry_designer_payout_attempt_path(@attempt)
    end
    assert_redirected_to designer_payouts_path(anchor: "payout-attention")
    follow_redirect!
    assert_select ".flash-bad", text: /can no longer be retried/
    assert_equal "reconciliation_required", @attempt.reload.status
  end

  test "already-paid shares reconcile without queuing a duplicate transfer" do
    other = designers(:one)
    other_purchase = delivered_purchase(other)
    other_attempt = PayoutAttempt.create!(designer: other, purchase: other_purchase,
      ref: @attempt.ref, asset: other_purchase.asset, status: "failed", attempt_count: 10,
      last_error_code: "service_unavailable")
    LedgerEntry.create!(purchase: @purchase, designer: @designer, entry_kind: "designer_payout",
      asset: @purchase.asset, amount_base_units: 225_000, held_by: "designer",
      tx_id: "0.0.9067781@1.1")

    assert_no_enqueued_jobs(only: DesignerPayoutJob) do
      post retry_designer_payout_attempt_path(@attempt)
    end

    assert_redirected_to designer_payouts_path(anchor: "payout-attention")
    assert_equal [ "succeeded", "0.0.9067781@1.1" ],
      @attempt.reload.values_at("status", "tx_id")
    assert_equal 1, LedgerEntry.where(purchase: @purchase, entry_kind: "designer_payout").count
    assert_equal "failed", other_attempt.reload.status
  end

  test "retry requires a recent password and returns to Payouts after confirmation" do
    travel 6.minutes do
      post retry_designer_payout_attempt_path(@attempt)
      assert_redirected_to "/confirm-password"

      post "/confirm-password", params: { password: "password" }
      assert_redirected_to designer_payouts_path(anchor: "payout-destination")
    end
    assert_equal "failed", @attempt.reload.status
    assert_no_enqueued_jobs(only: DesignerPayoutJob)
  end

  test "retry is tenant-scoped and requires authentication" do
    other = designers(:one)
    other.update!(hedera_account_id: "0.0.8008")
    other.update!(payout_account_verified_at: Time.current)
    other_purchase = delivered_purchase(other)
    other_attempt = PayoutAttempt.create!(designer: other, purchase: other_purchase,
      ref: "purchase-#{other_purchase.id}", asset: other_purchase.asset, status: "failed",
      attempt_count: 10, last_error_code: "service_unavailable")

    post retry_designer_payout_attempt_path(other_attempt)
    assert_response :not_found
    assert_equal "failed", other_attempt.reload.status

    sign_out
    post retry_designer_payout_attempt_path(@attempt)
    assert_redirected_to "/login"
  end

  private

  def delivered_purchase(designer, buyer_hint: nil)
    model = designer.models3d.create!(title: "Payout recovery",
      slug: "payout-recovery-#{SecureRandom.hex(4)}")
    offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    purchase = Purchase.create!(license_offer: offer, status: "verified", buyer_hint: buyer_hint,
      asset: "0.0.429274", amount_base_units: "250000", replay_key: SecureRandom.hex(32),
      requirements_json: { "payTo" => "0.0.9584959" })
    purchase.transition_to!(:settled)
    License.allocate!(purchase)
    purchase.transition_to!(:delivered)
    purchase
  end
end
