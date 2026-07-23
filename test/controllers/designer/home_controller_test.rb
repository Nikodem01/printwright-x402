require "test_helper"
require "webmock/minitest"

class Designer::HomeControllerTest < ActionDispatch::IntegrationTest
  setup do
    ENV["X402_PAY_TO"] = "0.0.9584959"
    stub_request(:get, %r{api\.pwnedpasswords\.com/range/}).to_return(status: 200, body: "")
    @designer = designers(:two)
    sign_in_as @designer
  end

  test "new designer sees truthful readiness and direct first actions" do
    sign_out
    post "/create-account", params: {
      display_name: "First Day Studio", email: "first-day@example.com",
      password: "verdigris-kettle-9-monsoon"
    }
    assert_redirected_to designer_root_path
    @designer = Designer.find_by!(email_address: "first-day@example.com")

    get designer_root_path

    assert_response :success
    assert_select "h1", text: @designer.display_name
    assert_select ".home-heading", text: /shop is not live yet/i
    assert_select "#setup-title", text: "0 of 4 operational steps complete"
    assert_select ".home-checklist", text: /Email verified.*To do.*Catalog started.*To do.*Listing live.*To do.*Payout destination ready.*To do/m
    assert_select ".home-task", text: /Verify your email.*Send verification email/m
    assert_select "form[action='/verify-account-resend'][method='post']" do
      assert_select "input[name='email'][value=?]", @designer.email_address
      assert_select "button", text: "Send verification email"
    end
    assert_select ".home-task", text: /Add your first model.*Upload a model/m
    assert_select ".home-task", text: /Set up a payout destination.*Buyer checkout and delivery do not wait/m
    assert_select ".home-recovery-support a[href=?]",
      "https://github.com/Nikodem01/printwright-x402/issues/new", text: "Open a marketplace support issue"
    assert_select ".home-recovery-support", text: /never post wallet signatures.*webhook secrets.*buyer data/i
    assert_select "a[href=?]", new_designer_model_path
    assert_select "a[href=?]", designer_imports_path
    assert_select ".home-metric", text: /Gross sales.*0\.00 USDC/m
    assert_select "#performance-title", text: "Delivered sales by model"
    assert_select ".home-sample", text: /What buyers will see.*Readable license and price.*Verifiable purchase certificate/m

    Designer.connection.execute(
      "UPDATE account_verification_keys SET email_last_sent = CURRENT_TIMESTAMP - INTERVAL '10 minutes' " \
      "WHERE id = #{Integer(@designer.id)}"
    )
    previous_sent_at = Designer.connection.select_value(
      "SELECT email_last_sent FROM account_verification_keys WHERE id = #{Integer(@designer.id)}"
    )
    post "/verify-account-resend", params: { email: @designer.email_address }
    assert_redirected_to designer_root_path
    current_sent_at = Designer.connection.select_value(
      "SELECT email_last_sent FROM account_verification_keys WHERE id = #{Integer(@designer.id)}"
    )
    assert_operator current_sent_at, :>, previous_sent_at
  end

  test "activated designer with no sales sees live state without invented analytics" do
    @designer.update!(hedera_account_id: "0.0.7007")
    @designer.update!(payout_account_verified_at: Time.current,
      payout_account_control_verified_at: Time.current,
      identity_verified_at: Time.current,
      verified_profile_url: "https://example.com/studio")
    create_model(title: "Live organizer", status: "published", mesh_analysis_status: "passed")

    get designer_root_path

    assert_response :success
    assert_select ".home-heading", text: /shop is live.*1 listing/m
    assert_select "#setup-title", text: "4 of 4 operational steps complete"
    assert_select ".home-card", text: /Public identity verified/
    assert_select "[role=status]", text: /No urgent actions/
    assert_select ".home-metric", text: /Delivered sales.*0/m
    assert_select "#performance-title + p", text: /does not invent view or conversion data/
    assert_select ".home-sample", count: 0
  end

  test "selling designer sees ledger-backed totals, private-safe activity, and seller health alerts" do
    @designer.update!(hedera_account_id: "0.0.7007")
    @designer.update!(payout_account_verified_at: Time.current,
      payout_account_control_verified_at: Time.current)
    model = create_model(title: "Seller metric lamp", status: "published", mesh_analysis_status: "passed")
    purchase = delivered_purchase(model, buyer_hint: "private-buyer-0.0.12345")
    license = License.allocate!(purchase)
    endpoint = @designer.webhook_endpoints.build(
      url: "https://hooks.example.com/sales", events: [ "sale.completed" ], secret_ciphertext: "encrypted"
    )
    endpoint.save!(validate: false)
    WebhookDelivery.create!(webhook_endpoint: endpoint, license: license, status: "failed",
      target_kind: "designer", event_type: "sale.completed", event_key: SecureRandom.hex(16),
      event_id: SecureRandom.uuid, url: endpoint.url, secret_ciphertext: "encrypted")

    get designer_root_path

    assert_response :success
    assert_select ".home-metric", text: /Delivered sales.*1/m
    assert_select ".home-metric", text: /Gross sales.*1\.00 USDC/m
    assert_select ".home-metric", text: /Your net after 10% fee.*0\.90 USDC/m
    assert_select ".home-metric", text: /Awaiting payout.*0\.90 USDC.*Eligible for automatic payout/m
    assert_select ".home-task", text: /Certificate anchoring is delayed.*Buyer delivery remains available/m
    assert_select ".home-task", text: /Webhook delivery needs attention.*independently of buyer settlement and delivery.*Retry failed delivery/m
    assert_select ".home-task a[href=?]", designer_webhook_endpoints_path(anchor: "delivery-health")
    assert_select ".home-ranking", text: /Seller metric lamp.*1 sale/m
    assert_select ".home-activity", text: /Sale delivered.*Seller metric lamp.*Personal.*1\.00 USDC/m
    assert_no_match "private-buyer-0.0.12345", response.body
    assert_no_match purchase.replay_key, response.body
  end

  test "blocked drafts and staged security work become direct recovery tasks" do
    create_model(title: "Failed draft", status: "draft", mesh_analysis_status: "failed")
    create_model(title: "Pending draft", status: "draft", mesh_analysis_status: "pending")
    @designer.update!(payout_pending_account_id: "0.0.8123",
      payout_challenge: "challenge", payout_challenge_digest: "digest",
      payout_challenge_expires_at: 10.minutes.from_now,
      payout_change_requested_at: Time.current)
    @designer.profile_verifications.create!(status: "failed",
      profile_url: "https://example.com/designer", host: "example.com",
      challenge_token: "proof", expires_at: 10.minutes.from_now)

    get designer_root_path

    assert_response :success
    failed = @designer.models3d.find_by!(title: "Failed draft")
    assert_select ".home-task", text: /Finish 2 draft listings.*1 draft has a failed mesh check.*Fix failed analysis/m
    assert_select ".home-task a[href=?]", edit_designer_model_path(failed, anchor: "files")
    assert_select ".home-task", text: /Finish the payout destination change.*exact staged wallet.*Sign wallet proof/m
    assert_select ".home-task", text: /Retry public identity verification.*Retry proof/m
  end

  test "owed earnings stay visibly held until payout setup is ready" do
    model = create_model(title: "Held earnings model", status: "published", mesh_analysis_status: "passed")
    purchase = delivered_purchase(model)
    License.allocate!(purchase).update!(hcs_sequence_number: 10, hcs_topic_id: "0.0.10")

    get designer_root_path

    assert_response :success
    assert_select ".home-metric", text: /Awaiting payout.*0\.90 USDC.*Held until destination is ready/m
    assert_select ".home-task", text: /Unlock earnings awaiting payout.*Buyer checkout and delivery do not wait/m
    assert_select ".home-task a[href=?]", designer_payouts_path(anchor: "payout-destination"),
      text: "Set up payouts"
  end

  test "failed payout operations become a private recovery task" do
    @designer.update!(hedera_account_id: "0.0.7007")
    @designer.update!(payout_account_verified_at: Time.current)
    model = create_model(title: "Payout issue model", status: "published", mesh_analysis_status: "passed")
    purchase = delivered_purchase(model, buyer_hint: "hidden-buyer")
    PayoutAttempt.create!(designer: @designer, purchase: purchase,
      ref: "purchase-#{purchase.id}", asset: purchase.asset, status: "failed",
      attempt_count: 10, last_error_code: "service_unavailable")

    get designer_root_path

    assert_select ".home-task", text: /Resolve a payout transfer.*1 sale.*Buyer delivery and rights remain complete.*Review payout state/m
    assert_select ".home-task a[href=?]", designer_payouts_path(anchor: "payout-attention")
    assert_no_match "hidden-buyer", response.body
  end

  test "a catalog with only paused or retired models prompts an availability review" do
    create_model(title: "Paused listing", status: "paused", mesh_analysis_status: "passed")
    create_model(title: "Retired listing", status: "retired", mesh_analysis_status: "passed")

    get designer_root_path

    assert_response :success
    assert_select ".home-task", text: /Reopen sales.*no published listing.*Review models/m
  end

  test "home excludes every other designer's models, sales, and alerts" do
    own_model = create_model(title: "Own listing", status: "published", mesh_analysis_status: "passed")
    own_purchase = delivered_purchase(own_model)
    License.allocate!(own_purchase).update!(hcs_sequence_number: 10, hcs_topic_id: "0.0.10")

    other = designers(:one)
    other_model = other.models3d.create!(title: "Other secret listing",
      slug: "other-secret-#{SecureRandom.hex(4)}", status: "published", mesh_analysis_status: "passed")
    other_model.license_offers.create!(kind: "personal", price_cents: 900)
    other_purchase = delivered_purchase(other_model, amount: "9000000")
    License.allocate!(other_purchase)

    get designer_root_path

    assert_response :success
    assert_select ".home-metric", text: /Delivered sales.*1/m
    assert_select ".home-metric", text: /Gross sales.*1\.00 USDC/m
    assert_no_match "Other secret listing", response.body
    assert_no_match "9.00 USDC", response.body
  end

  test "home requires authentication" do
    sign_out

    get designer_root_path

    assert_redirected_to "/login"
  end

  private

  def create_model(title:, status:, mesh_analysis_status: "pending")
    model = @designer.models3d.create!(title: title,
      slug: "#{title.parameterize}-#{SecureRandom.hex(4)}", status: status,
      mesh_analysis_status: mesh_analysis_status)
    model.license_offers.create!(kind: "personal", price_cents: 100)
    model
  end

  def delivered_purchase(model, amount: "1000000", buyer_hint: nil)
    offer = model.license_offers.first
    purchase = Purchase.create!(license_offer: offer, status: "verified", amount_base_units: amount,
      asset: X402::Requirements.usdc_asset, replay_key: SecureRandom.hex(32), buyer_hint: buyer_hint,
      requirements_json: { "payTo" => ENV.fetch("X402_PAY_TO") })
    purchase.transition_to!(:settled)
    purchase.transition_to!(:delivered)
    purchase
  end
end
