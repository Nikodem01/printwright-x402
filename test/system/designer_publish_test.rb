require "application_system_test_case"
require "webmock/minitest"

# The designer door through the real forms: sign up, upload a model, get the
# warranty gate refusal, then publish for real and land on the public page.
class DesignerPublishTest < RackSystemTestCase
  setup do
    WebMock.disable_net_connect!(allow_localhost: true)
    # Signup checks the password against Have I Been Pwned; keep it offline.
    stub_request(:get, %r{api\.pwnedpasswords\.com/range/}).to_return(status: 200, body: "")
  end

  test "sign up, upload, hit the warranty gate, publish, land on the live page" do
    visit "/create-account"
    fill_in "Studio / display name", with: "Form Flow Studio"
    fill_in "Email address", with: "formflow@example.com"
    fill_in "Password", with: "verdigris-kettle-9-monsoon"
    click_button "Create Account"

    # Publishing is gated on a verified email (S2); simulate clicking the link.
    Designer.find_by!(email_address: "formflow@example.com").account_verified!

    visit new_designer_model_path
    fill_in "Title", with: "Form Flow Clip"
    fill_in "Tags (comma-separated)", with: "cable, clip"
    assert_text "Canonical personal license (#{Licensing::Documents::CURRENT_VERSION})"
    assert_text "Personal Print License"
    assert_no_field "Terms"
    attach_file "Printable files (STL/3MF, plus optional STEP source)",
      Rails.root.join("db/seed_assets/calibration-cube.stl")
    click_button "Save draft"
    assert_text "Saved as draft."

    model = Model3d.find_by!(slug: "form-flow-clip")
    assert model.draft?

    AnalyzeModelMeshJob.perform_now(model.id)
    visit edit_designer_model_path(model)
    assert_text "Mesh analysis: passed"

    click_button "Review and publish"
    assert_text "Review and publish"
    assert_text "Form Flow Clip"
    assert_text "calibration-cube.stl"
    assert_text "Personal"
    assert_text "2.50 USDC"
    assert_text "Your share after 10% fee"
    assert model.reload.draft?

    # Final confirmation without the recorded warranty must bounce, not go live.
    click_button "Publish — freeze the bundle hash and go live"
    assert_text(/warranty/i)
    assert model.reload.draft?

    click_button "Review and publish"
    check "warranty"
    click_button "Publish — freeze the bundle hash and go live"

    assert_current_path model_page_path("form-flow-clip")
    assert_text "Form Flow Clip"
    assert_text "Buy a license"
    # The buyer's first look exists the moment the listing is live — the cover
    # is rendered during publish, not by the job queued behind it.
    assert model.reload.render_files.any? { |file| file.file.attached? }
    assert_selector ".gallery img"
    model.reload
    assert model.published?
    assert_match(/\Asha256:[0-9a-f]{64}\z/, model.file_hash)

    visit edit_designer_model_path(model)
    click_button "Pause new sales"
    assert_text "Sales paused"
    assert model.reload.paused?

    visit root_path
    within "#models" do
      assert_no_text "Form Flow Clip"
    end
    visit model_page_path(model.slug)
    assert_text "Sales paused"
    assert_no_button "Buy license · 2.50 USDC"

    visit edit_designer_model_path(model)
    click_button "Resume new sales"
    assert_text "Sales resumed"
    assert model.reload.published?
  end
end
