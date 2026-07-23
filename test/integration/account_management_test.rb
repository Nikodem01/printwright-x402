require "test_helper"

# Self-service account management (U1) + GDPR export/erasure (U2).
class AccountManagementTest < ActionDispatch::IntegrationTest
  test "account page renders profile, sessions, and security controls" do
    sign_in_as designers(:two)
    get designer_account_path
    assert_response :success
    assert_select "h1", text: "Account"
    assert_select "a[href=?]", "/change-password"
    assert_select "a[href=?]", export_designer_account_path
  end

  test "account page moves payout settings to Payouts" do
    sign_in_as designers(:two)

    get designer_account_path

    assert_select "a[href=?]", designer_payouts_path(anchor: "payout-destination"), text: "Payouts"
    assert_select "input[name='designer[hedera_account_id]']", count: 0
  end

  test "designer edits their profile" do
    sign_in_as designers(:two)
    patch designer_account_path, params: { designer: {
      display_name: "Renamed Studio", bio: "New bio", hedera_account_id: "0.0.777"
    } }
    assert_redirected_to designer_account_path
    designers(:two).reload.tap do |d|
      assert_equal "Renamed Studio", d.display_name
      assert_equal "New bio", d.bio
      assert_nil d.hedera_account_id, "profile updates cannot bypass payout proof"
    end
    follow_redirect!
    assert_select ".flash-ok[role='status']" # success is announced politely
  end

  test "profile update rejects a blank display name" do
    sign_in_as designers(:two)
    patch designer_account_path, params: { designer: { display_name: "" } }
    assert_response :unprocessable_entity
    assert_select ".flash-bad[role='alert']" # errors are announced assertively
    # The message is also tied to its own field for assistive tech.
    assert_select "input#designer_display_name[aria-invalid='true'][aria-describedby='designer_display_name_error']"
    assert_select "p#designer_display_name_error.field-error"
    assert designers(:two).reload.display_name.present?
  end

  test "designer sets optional trust fields, links one per line, and an own featured model" do
    designer = designers(:two)
    featured = designer.models3d.create!(title: "Feature Me", slug: "feature-me-#{SecureRandom.hex(4)}",
      status: "published")
    sign_in_as designer

    patch designer_account_path, params: { designer: {
      display_name: designer.display_name, specialty: "Print-in-place mechanisms",
      location: "Adelaide, Australia",
      profile_links_text: "https://github.com/studio-two\n\nhttps://www.printables.com/@studio-two",
      featured_model_id: featured.id
    } }

    assert_redirected_to designer_account_path
    designer.reload
    assert_equal "Print-in-place mechanisms", designer.specialty
    assert_equal "Adelaide, Australia", designer.location
    assert_equal %w[https://github.com/studio-two https://www.printables.com/@studio-two],
      designer.profile_links
    assert_equal featured.id, designer.featured_model_id
  end

  test "profile links refuse http, credentials, and more than three entries" do
    sign_in_as designers(:two)

    patch designer_account_path, params: { designer: {
      display_name: designers(:two).display_name,
      profile_links_text: "http://insecure.example/profile"
    } }
    assert_response :unprocessable_entity

    patch designer_account_path, params: { designer: {
      display_name: designers(:two).display_name,
      profile_links_text: "https://user:pass@github.com/x"
    } }
    assert_response :unprocessable_entity

    patch designer_account_path, params: { designer: {
      display_name: designers(:two).display_name,
      profile_links_text: (1..4).map { |i| "https://example.com/#{i}" }.join("\n")
    } }
    assert_response :unprocessable_entity
    assert_empty Array(designers(:two).reload.profile_links)
  end

  test "featured model cannot point at another studio's listing" do
    other_model = designers(:one).models3d.create!(title: "Not Yours",
      slug: "not-yours-#{SecureRandom.hex(4)}", status: "published")
    sign_in_as designers(:two)

    patch designer_account_path, params: { designer: {
      display_name: designers(:two).display_name, featured_model_id: other_model.id
    } }

    assert_response :unprocessable_entity
    assert_nil designers(:two).reload.featured_model_id
  end

  test "data export returns JSON without any credential material" do
    designer = designers(:two)
    model = designer.models3d.create!(title: "Export payout", slug: "export-payout-#{SecureRandom.hex(4)}")
    offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    purchase = Purchase.create!(license_offer: offer, status: "pending", replay_key: SecureRandom.hex(32))
    PayoutAttempt.create!(designer: designer, purchase: purchase, ref: "purchase-#{purchase.id}",
      asset: "0.0.429274", status: "failed", attempt_count: 10,
      last_error_code: "service_unavailable")
    ModelMetric.record!(model_ids: [ model.id ], event: "impression",
      channel: "human", source: "profile", occurred_on: "2026-07-23")
    sign_in_as designer
    get export_designer_account_path
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal designer.email_address, body.dig("account", "email_address")
    assert_equal [ "failed", "service_unavailable", 10 ],
      body.fetch("payout_attempts").sole.values_at("status", "last_error_code", "attempt_count")
    assert_equal [ "human", "profile", 1, 0, 0 ],
      body.fetch("model_metrics").sole.values_at(
        "channel", "source", "impressions", "views", "payment_requests"
      )
    refute response.body.include?(designer.password_digest)
    refute_match(/password_digest|otp|recovery/i, response.body)
  end

  test "sign out other devices keeps this session, drops the rest" do
    designer = designers(:two)
    designer.active_session_keys.create!(session_id: "another-device")
    sign_in_as designer
    assert_operator designer.active_session_keys.count, :>=, 2

    post revoke_other_sessions_designer_account_path
    assert_redirected_to designer_account_path
    assert_equal 1, designer.reload.active_session_keys.count
    refute designer.active_session_keys.exists?(session_id: "another-device")
  end

  test "the account marks the current session and offers per-device sign out" do
    designer = designers(:two)
    designer.active_session_keys.create!(session_id: "other-device")
    sign_in_as designer

    get designer_account_path
    assert_response :success
    assert_select "table.account-sessions .badge", text: "This session"
    assert_select "form[action=?]", revoke_session_designer_account_path(session_id: "other-device")
    assert_includes response.body, "no IP address, device, or location"
  end

  test "signing out one device drops only that session and keeps the current one" do
    designer = designers(:two)
    designer.active_session_keys.create!(session_id: "other-device")
    sign_in_as designer

    post revoke_session_designer_account_path(session_id: "other-device")

    assert_redirected_to designer_account_path
    refute designer.active_session_keys.exists?(session_id: "other-device")
    assert_operator designer.reload.active_session_keys.count, :>=, 1
  end

  test "a designer cannot sign out their own current session from the list" do
    designer = designers(:two)
    sign_in_as designer
    current_id = designer.active_session_keys.order(:created_at).last.session_id

    post revoke_session_designer_account_path(session_id: current_id)

    follow_redirect!
    assert_select ".flash-bad", text: /current session/
    assert designer.active_session_keys.exists?(session_id: current_id)
  end

  test "revoke_session cannot touch another studio's session" do
    victim = designers(:one)
    victim.active_session_keys.create!(session_id: "victim-device")
    sign_in_as designers(:two)

    post revoke_session_designer_account_path(session_id: "victim-device")

    assert victim.active_session_keys.exists?(session_id: "victim-device")
  end

  test "closure is explicit, retires purchase history, removes private work, and preserves buyer rights" do
    designer = designers(:two)
    designer.update!(
      display_name: "Historical Studio", bio: "Private bio", hedera_account_id: "0.0.7007",
      verified: true, identity_verified_at: Time.current,
      verified_profile_url: "https://example.com/historical-studio"
    )
    designer.update!(payout_account_verified_at: Time.current,
      payout_account_control_verified_at: Time.current)
    model = designer.models3d.create!(
      title: "Licensed history", slug: "licensed-history-#{SecureRandom.hex(3)}",
      status: "published", file_hash: "sha256:#{'a' * 64}"
    )
    file = model.model_files.create!(kind: "stl")
    file.file.attach(io: StringIO.new("solid history\nendsolid history\n"),
      filename: "history.stl", content_type: "model/stl")
    offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    purchase = Purchase.create!(
      license_offer: offer, status: "delivered", replay_key: SecureRandom.hex(32),
      buyer_hint: "0.0.8008", payment_tx_id: "0.0.8@1.2"
    )
    license = License.allocate!(purchase)
    license.update!(cert_json: Certificates::Builder.call(license))
    receipt_token = license.signed_id(purpose: "purchase-receipt")
    updates_token = license.signed_id(purpose: "model-updates")
    draft = designer.models3d.create!(
      title: "Private draft", slug: "private-closure-#{SecureRandom.hex(3)}"
    )
    buyer = open_session
    buyer.post cart_items_path, params: { model_id: model.id, license: "personal" }
    assert_equal 302, buyer.response.status
    designer.active_session_keys.create!(session_id: "closure-other-device")
    sign_in_as designer

    get "/close-account"
    assert_response :success
    assert_select "h1", text: "Close account"
    assert_select "li", text: /Deletes 1 listing.*no purchase history/m
    assert_select "li", text: /Retires 1 purchase-backed listing.*new human\/API\/agent checkout/m
    assert_select "li", text: /Preserves existing buyers.*receipts.*certificates.*downloads/m

    post "/close-account", params: { password: "password" }
    assert_response :unprocessable_entity
    assert_select "#closure_error_message", text: /Confirm that you understand/
    assert_not designer.reload.account_closed?

    post "/close-account", params: { password: "password", understand: "1" }

    designer.reload
    assert designer.account_closed?
    assert_equal "Historical Studio", designer.display_name
    assert_match(/\Aclosed-#{designer.id}@/, designer.email_address)
    assert_nil designer.password_digest
    assert_nil designer.bio
    assert_nil designer.hedera_account_id
    assert_nil designer.payout_account_verified_at
    assert_not designer.verified?
    assert_nil designer.verified_profile_url
    assert_empty designer.active_session_keys
    assert_predicate model.reload, :retired?
    assert_not Model3d.exists?(draft.id)
    assert License.exists?(license.id)

    get root_path
    assert_no_match model.title, response.body
    get api_v1_model_path(model)
    assert_response :not_found
    get api_v1_model_download_path(model_id: model.id, license: "personal")
    assert_response :gone
    assert_equal "listing_retired", response.parsed_body["error"]
    post api_v1_batches_path, params: {
      items: [ { model_id: model.id, license: "personal" } ]
    }
    assert_response :gone
    assert_equal "listing_retired", response.parsed_body["error"]
    get model_page_path(model.slug)
    assert_response :success
    assert_select "h1", text: model.title
    assert_select "button", text: /Buy/, count: 0

    get purchase_receipt_path(license.cert_id), params: { token: receipt_token }
    assert_response :success
    assert_select "dd", text: /Personal/
    get purchase_receipt_download_path(license.cert_id), params: { token: receipt_token }
    assert_redirected_to api_v1_file_path(DownloadGrant.order(:id).last.token)
    get verify_path(license.verify_slug)
    assert_response :success
    assert_select ".cert-model", text: /Historical Studio/
    get verify_certificate_path(license.verify_slug)
    assert_response :success
    assert_match "Historical Studio", response.body
    get api_v1_license_latest_version_path(license.cert_id),
      headers: { "Authorization" => "Bearer #{updates_token}" }
    assert_response :success
    assert_equal model.file_hash, response.parsed_body["file_hash"]

    buyer.get cart_path
    assert_equal 200, buyer.response.status
    cart = Nokogiri::HTML(buyer.response.body)
    assert_empty cart.css(".cart-line")
    assert_includes cart.at_css(".cart-empty").text, "Your cart is empty"

    get designer_path(designer)
    assert_response :success
    assert_select 'meta[name="robots"][content="noindex"]'
    assert_select "h1", text: "Historical Studio"
    assert_select ".empty-state", text: /account closed.*Existing licenses.*downloads/m
    assert_no_match "Private bio", response.body
    assert_no_match "0.0.7007", response.body
  end

  test "closure is blocked with a direct recovery path while earnings remain owed" do
    designer = designers(:two)
    model = designer.models3d.create!(
      title: "Owed closure", slug: "owed-closure-#{SecureRandom.hex(3)}", status: "published"
    )
    offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    purchase = Purchase.create!(
      license_offer: offer, status: "verified", replay_key: SecureRandom.hex(32),
      asset: "0.0.429274", amount_base_units: "250000",
      requirements_json: { "payTo" => "0.0.9584959" }
    )
    purchase.transition_to!(:settled)
    sign_in_as designer

    get "/close-account"
    assert_response :success
    assert_select '[role="alert"]', text: /Closure is currently blocked.*Payouts.*0\.22 USDC/m
    assert_select 'input[type="submit"][disabled]'

    post "/close-account", params: { password: "password", understand: "1" }

    assert_response :unprocessable_entity
    assert_select "#closure_error_message", text: /earnings owed.*Payouts/m
    assert_not designer.reload.account_closed?
    assert_predicate model.reload, :published?
  end
end
