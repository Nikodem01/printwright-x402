require "application_system_test_case"
require "webmock/minitest"

# The designer door through the real forms: sign up, upload a model, get the
# warranty gate refusal, then publish for real and land on the public page.
class DesignerPublishTest < RackSystemTestCase
  setup do
    WebMock.disable_net_connect!(allow_localhost: true)
    # Signup checks the password against Have I Been Pwned; keep it offline.
    stub_request(:get, %r{api\.pwnedpasswords\.com/range/}).to_return(status: 200, body: "")
    # Publish runs the payout-account mirror check; this account can receive
    # USDC directly (unlimited auto-association), same stub as the API tests.
    stub_request(:get, %r{testnet\.mirrornode\.hedera\.com/api/v1/accounts/0\.0\.42/tokens})
      .to_return(body: { tokens: [], links: {} }.to_json, headers: { "content-type" => "application/json" })
    stub_request(:get, %r{testnet\.mirrornode\.hedera\.com/api/v1/accounts/0\.0\.42\z})
      .to_return(body: { max_automatic_token_associations: -1 }.to_json, headers: { "content-type" => "application/json" })
  end

  test "sign up, upload, hit the warranty gate, publish, land on the live page" do
    visit "/create-account"
    fill_in "Studio / display name", with: "Form Flow Studio"
    fill_in "Email address", with: "formflow@example.com"
    fill_in "Password", with: "verdigris-kettle-9-monsoon"
    fill_in "Hedera account id (payout target)", with: "0.0.42"
    click_button "Create Account"

    # Publishing is gated on a verified email (S2); simulate clicking the link.
    Designer.find_by!(email_address: "formflow@example.com").account_verified!

    visit new_designer_model_path
    fill_in "Title", with: "Form Flow Clip"
    fill_in "Tags (comma-separated)", with: "cable, clip"
    fill_in "Terms", with: "Personal print license."
    attach_file "Printable files (STL/3MF/STEP)", Rails.root.join("db/seed_assets/calibration-cube.stl")
    click_button "Save draft"
    assert_text "Saved as draft."

    model = Model3d.find_by!(slug: "form-flow-clip")
    assert model.draft?

    AnalyzeModelMeshJob.perform_now(model.id)
    visit edit_designer_model_path(model)
    assert_text "Mesh analysis: passed"

    # Publishing without the recorded warranty must bounce, not go live.
    click_button "Publish — freeze the bundle hash and go live"
    assert_text(/warranty/i)
    assert model.reload.draft?

    check "warranty"
    click_button "Publish — freeze the bundle hash and go live"

    assert_current_path model_page_path("form-flow-clip")
    assert_text "Form Flow Clip"
    assert_text "Buy a license"
    model.reload
    assert model.published?
    assert_match(/\Asha256:[0-9a-f]{64}\z/, model.file_hash)
  end
end
