require "test_helper"
require "webmock/minitest"

class DesignerFlowTest < ActionDispatch::IntegrationTest
  setup do
    # Publish runs the payout-account mirror check; this designer's account
    # can receive USDC directly (unlimited auto-association).
    stub_request(:get, %r{testnet\.mirrornode\.hedera\.com/api/v1/accounts/0\.0\.42/tokens})
      .to_return(body: { tokens: [], links: {} }.to_json, headers: { "content-type" => "application/json" })
    stub_request(:get, %r{testnet\.mirrornode\.hedera\.com/api/v1/accounts/0\.0\.42\z})
      .to_return(body: { max_automatic_token_associations: -1 }.to_json, headers: { "content-type" => "application/json" })
  end

  test "sign up -> upload -> publish makes the model live and API-buyable-shaped" do
    post designers_path, params: { designer: {
      display_name: "Flow Studio", email_address: "flow@example.com",
      password: "s3curepass", hedera_account_id: "0.0.42"
    } }
    assert_redirected_to designer_models_path

    stl = fixture_file_upload(Rails.root.join("db/seed_assets/calibration-cube.stl"), "model/stl")
    render_png = fixture_file_upload(Rails.root.join("db/seed_assets/calibration-cube.png"), "image/png")
    post designer_models_path, params: { model3d: {
      title: "Flow Test Widget", tags_text: "widget, flow",
      description: "Uploaded through the real form.",
      printability: { supports: "false", materials_text: "PLA", est_print_minutes: "30" },
      printable_files: [ stl ], render_files: [ render_png ],
      license_offers_attributes: { "0" => { kind: "personal", price_cents: "150", terms_md: "T." } }
    } }
    model = Model3d.find_by!(slug: "flow-test-widget")
    assert_redirected_to edit_designer_model_path(model)
    assert model.draft?
    assert_equal %w[widget flow], model.tags
    assert_equal false, model.printability["supports"]
    assert model.model_files.count == 2

    post publish_designer_model_path(model)
    model.reload
    assert model.published?
    assert_match(/\Asha256:[0-9a-f]{64}\z/, model.file_hash)

    get api_v1_models_url(q: "flow widget")
    assert_equal model.id, response.parsed_body["models"].first["id"]

    get model_page_path(model.slug)
    assert_response :success
  end

  test "publish refuses without files and without offers" do
    designer = designers(:one)
    sign_in_as designer
    model = designer.models3d.create!(title: "Bare", slug: "bare-#{SecureRandom.hex(3)}")
    post publish_designer_model_path(model)
    assert model.reload.draft?
    follow_redirect!
    assert_select ".flash-bad", text: /printable file/
  end

  test "designers cannot touch another designer's models" do
    sign_in_as designers(:two)
    model = designers(:one).models3d.create!(title: "Mine", slug: "mine-#{SecureRandom.hex(3)}")
    get edit_designer_model_path(model)
    assert_response :not_found
  end

  test "designer area requires authentication" do
    get designer_models_path
    assert_redirected_to new_session_path
  end

  private

  def sign_in_as(designer)
    post session_path, params: { email_address: designer.email_address, password: "password" }
  end
end
