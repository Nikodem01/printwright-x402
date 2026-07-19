require "application_system_test_case"
require "webmock/minitest"

class AdminOperationsTest < RackSystemTestCase
  include ActiveJob::TestHelper

  MIRROR = "https://testnet.mirrornode.hedera.com".freeze
  SIDECAR = "http://localhost:4021".freeze

  setup do
    ENV["X402_PAY_TO"] = "0.0.9584959"
    ENV["SIDECAR_TOKEN"] = "test-token"
    @admin = designers(:one)
    @admin.update!(hedera_account_id: "0.0.9604186")
    @admin.update!(payout_account_verified_at: Time.current)
    @designer = designers(:two)
    @designer.update!(verified: false)

    model = Model3d.create!(
      designer: @admin, title: "Operator Fixture", slug: "operator-#{SecureRandom.hex(4)}"
    )
    offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    @stuck = Purchase.create!(
      license_offer: offer, status: "pending", buyer_hint: "0.0.9067781",
      asset: "0.0.429274", amount_base_units: "250000", replay_key: SecureRandom.hex(32),
      requirements_json: { "payTo" => "0.0.9584959", "amount" => "250000", "asset" => "0.0.429274" },
      created_at: 2.hours.ago
    )
    @refundable = settled_purchase(offer)
    cert_purchase = settled_purchase(offer)
    @license = License.allocate!(cert_purchase)
    cert_purchase.transition_to!(:delivered)

    stub_request(:get, %r{#{MIRROR}/api/v1/transactions\?account\.id=0\.0\.9584959})
      .to_return(body: { transactions: [] }.to_json, headers: { "content-type" => "application/json" })
    stub_request(:get, "#{MIRROR}/api/v1/network/nodes?limit=1")
      .to_return(body: "{}", headers: { "content-type" => "application/json" })
    stub_request(:post, "#{SIDECAR}/payout")
      .to_return(body: { transactionId: "0.0.9067781@88.99" }.to_json,
                 headers: { "content-type" => "application/json" })

    visit new_session_path
    fill_in "Enter your email address", with: @admin.email_address
    fill_in "Enter your password", with: "password"
    click_button "Sign in"
    assert_current_path root_path
    visit admin_root_path
  end

  test "operator executes recovery controls and sees immutable audit evidence" do
    assert_text "Operations"
    assert_text "Ledger totals"
    assert_text "Operator Fixture"

    click_button "Reconcile ##{@stuck.id}"
    assert_text "failed stale"
    assert @stuck.reload.failed_verification?

    click_button "Refund ##{@refundable.id}"
    assert_text "refunded"
    assert @refundable.reload.refunded?

    click_button "Retry #{@license.cert_id}"
    assert_text "queued for retry"
    assert enqueued_jobs.any? { |job| job[:job] == CertMintJob && job[:args] == [ @license.id ] }

    within("tr", text: @designer.email_address) { click_button "Mark verified" }
    assert_text "is now verified"
    assert @designer.reload.verified?

    actions = AdminAuditLog.order(:id).pluck(:action)
    assert_includes actions, "purchase_reconcile_completed"
    assert_includes actions, "purchase_refund_completed"
    assert_includes actions, "certificate_retry_enqueued"
    assert_includes actions, "designer_verification_toggled"
    assert AdminAuditLog.all.all?(&:readonly?)
  end

  private

  def settled_purchase(offer)
    purchase = Purchase.create!(
      license_offer: offer, status: "verified", buyer_hint: "0.0.9067781",
      asset: "0.0.429274", amount_base_units: "250000", replay_key: SecureRandom.hex(32),
      requirements_json: { "payTo" => "0.0.9584959" }
    )
    purchase.transition_to!(:settled)
    purchase
  end
end
