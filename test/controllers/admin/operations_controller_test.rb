require "test_helper"
require "webmock/minitest"

class Admin::OperationsControllerTest < ActionDispatch::IntegrationTest
  teardown { RateLimitStore.backend = nil }

  test "operator panel requires authentication and an admin grant" do
    get admin_root_path
    assert_redirected_to "/login"

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


  test "refused money actions are audited without changing state" do
    admin = designers(:one)
    model = Model3d.create!(designer: admin, title: "Final State", slug: "final-state")
    offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    purchase = Purchase.create!(license_offer: offer, status: "delivered",
      replay_key: SecureRandom.hex(32))
    sign_in_as admin

    post reconcile_admin_purchase_path(purchase)

    assert_redirected_to admin_root_path
    assert purchase.reload.delivered?
    assert_equal "purchase_reconcile_refused", AdminAuditLog.order(:id).last.action
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

  # Certificate retry is the operator's only lever when an HCS anchor fails, and
  # it was the one money-adjacent admin action with no coverage at all.
  test "operator can requeue an unanchored certificate, and cannot requeue an anchored one" do
    admin = designers(:one)
    license = unanchored_license(admin, slug: "retry-cert")
    sign_in_as admin

    assert_enqueued_with(job: CertMintJob, args: [ license.id ]) do
      post retry_certificate_admin_license_path(license)
    end

    assert_redirected_to admin_root_path
    follow_redirect!
    assert_select ".flash-ok", text: /#{license.cert_id} queued for retry/
    assert_equal %w[certificate_retry_requested certificate_retry_enqueued],
                 AdminAuditLog.order(:id).last(2).map(&:action)

    # Anchoring is final: a second run must not double-anchor the same license.
    license.update!(hcs_topic_id: "0.0.9585069", hcs_sequence_number: 42)

    assert_no_enqueued_jobs only: CertMintJob do
      post retry_certificate_admin_license_path(license)
    end

    assert_redirected_to admin_root_path
    follow_redirect!
    assert_select ".flash-bad", text: /#{license.cert_id} is already anchored/
    audit = AdminAuditLog.order(:id).last
    assert_equal "certificate_retry_refused", audit.action
    assert_equal "already_anchored", audit.details["reason"]
  end

  test "a sandbox certificate is not reachable by the operator retry lever" do
    admin = designers(:one)
    license = unanchored_license(admin, slug: "retry-sandbox", sandbox: true)
    sign_in_as admin

    assert_no_enqueued_jobs only: CertMintJob do
      post retry_certificate_admin_license_path(license)
    end

    assert_redirected_to admin_root_path
    follow_redirect!
    assert_select ".flash-bad", text: /Certificate retry failed/
    assert_equal "certificate_retry_failed", AdminAuditLog.order(:id).last.action
  end

  test "operator panel surfaces reconciliation-required payouts without rerunning them" do
    ENV["X402_PAY_TO"] = "0.0.9584959"
    admin = designers(:one)
    model = admin.models3d.create!(title: "Ambiguous payout", slug: "ambiguous-payout-#{SecureRandom.hex(4)}")
    offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    purchase = Purchase.create!(license_offer: offer, status: "verified", asset: "0.0.429274",
      amount_base_units: "250000", replay_key: SecureRandom.hex(32),
      requirements_json: { "payTo" => "0.0.9584959" })
    purchase.transition_to!(:settled)
    PayoutAttempt.create!(designer: admin, purchase: purchase, ref: "purchase-#{purchase.id}",
      asset: purchase.asset, status: "reconciliation_required", attempt_count: 1,
      last_error_code: "ambiguous_result", last_attempted_at: Time.current)
    sign_in_as admin

    get admin_root_path

    assert_select "h2", text: "Payout attention"
    assert_select ".facts-table", text: /Ambiguous payout|#{admin.display_name}.*purchase-#{purchase.id}.*0\.22 USDC.*Reconciliation required.*ambiguous_result/m
    assert_not_requested :post, "http://localhost:4021/payout"
  end

  private

  def unanchored_license(designer, slug:, sandbox: false)
    model = Model3d.create!(designer: designer, title: slug.titleize,
      slug: "#{slug}-#{SecureRandom.hex(4)}", status: "published", file_hash: "sha256:#{'a' * 64}")
    offer = model.license_offers.create!(kind: "personal", price_cents: 250, terms_md: "T.")
    purchase = Purchase.create!(license_offer: offer, status: "settled", sandbox: sandbox,
      replay_key: SecureRandom.hex(32), buyer_hint: "0.0.9067781",
      payment_tx_id: "0.0.7162784@111.222")
    License.allocate!(purchase).tap { purchase.transition_to!(:delivered) }
  end
end
