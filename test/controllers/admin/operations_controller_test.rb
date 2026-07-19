require "test_helper"
require "webmock/minitest"

class Admin::OperationsControllerTest < ActionDispatch::IntegrationTest
  teardown { RateLimitStore.backend = nil }

  test "operator panel requires authentication and an admin grant" do
    get admin_root_path
    assert_redirected_to new_session_path

    sign_in_as designers(:two)
    get admin_root_path
    assert_response :forbidden
    post toggle_verification_admin_designer_path(designers(:one))
    assert_response :forbidden
    assert_not designers(:one).reload.verified?

    sign_out
    sign_in_as designers(:one)
    get admin_root_path
    assert_response :success
    assert_select "h1", text: "Operations"
    assert_select "h2", text: "Ledger totals"
  end


  test "failed money actions are audited without changing state" do
    admin = designers(:one)
    model = Model3d.create!(designer: admin, title: "No Refund", slug: "no-refund")
    offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    purchase = Purchase.create!(license_offer: offer, replay_key: SecureRandom.hex(32))
    sign_in_as admin

    post refund_admin_purchase_path(purchase)

    assert_redirected_to admin_root_path
    assert purchase.reload.pending?
    assert_equal %w[purchase_refund_requested purchase_refund_failed],
      AdminAuditLog.order(:id).last(2).map(&:action)
  end

  test "status filter is constrained to purchase states" do
    sign_in_as designers(:one)

    get admin_root_path(status: "not-a-state")
    assert_response :success
    assert_select 'a[aria-pressed="true"]', text: "All"

    get admin_root_path(status: "settled")
    assert_response :success
    assert_select 'a[aria-pressed="true"]', text: "Settled"
  end

  test "operator pages are rate limited by admin and address" do
    RateLimitStore.backend = ActiveSupport::Cache::MemoryStore.new
    sign_in_as designers(:one)

    61.times { get admin_root_path }

    assert_response :too_many_requests
    assert_includes response.body, "Too many operator requests"
  end

  test "operator can preview and execute the existing payout runner" do
    ENV["X402_PAY_TO"] = "0.0.9584959"
    ENV["SIDECAR_TOKEN"] = "test-token"
    admin = designers(:one)
    admin.update!(hedera_account_id: "0.0.9604186")
    admin.update!(payout_account_verified_at: Time.current)
    model = Model3d.create!(designer: admin, title: "Admin Payout", slug: "admin-payout")
    offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    purchase = Purchase.create!(
      license_offer: offer, status: "verified", asset: "0.0.429274",
      amount_base_units: "250000", replay_key: SecureRandom.hex(32),
      requirements_json: { "payTo" => "0.0.9584959" }
    )
    purchase.transition_to!(:settled)
    sign_in_as admin

    post run_admin_payout_path
    assert_redirected_to admin_root_path
    assert_equal "payout_refused", AdminAuditLog.order(:id).last.action
    assert_not_requested :post, "http://localhost:4021/payout"

    post preview_admin_payout_path
    assert_redirected_to admin_root_path
    assert_equal "payout_previewed", AdminAuditLog.order(:id).last.action
    assert_not LedgerEntry.exists?(purchase: purchase, entry_kind: "designer_payout")

    stub = stub_request(:post, "http://localhost:4021/payout")
      .to_return(body: { transactionId: "0.0.9067781@7.8" }.to_json,
                 headers: { "content-type" => "application/json" })
    post run_admin_payout_path, params: { confirm: "1" }

    assert_redirected_to admin_root_path
    assert LedgerEntry.exists?(purchase: purchase, entry_kind: "designer_payout")
    assert_equal "payout_completed", AdminAuditLog.order(:id).last.action
    assert_requested stub, times: 1
  end
end
