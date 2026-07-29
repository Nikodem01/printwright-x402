require "test_helper"

class Designer::ProtectionControllerTest < ActionDispatch::IntegrationTest
  setup do
    @designer = designers(:one)
    sign_in_as @designer
    @model = @designer.models3d.create!(title: "Guarded Gadget",
      slug: "guarded-gadget-#{SecureRandom.hex(4)}", status: "published",
      file_hash: "sha256:#{'a' * 64}", geometry_hash: "geom:#{'b' * 32}")
    @offer = @model.license_offers.create!(kind: "personal", price_cents: 250)
  end

  test "authentication is required" do
    sign_out
    get designer_protection_path
    assert_redirected_to "/login"
  end

  test "lists this studio's fingerprints and blocked-copy counts without the attempter identity" do
    intruder = designers(:two)
    intruder.models3d.create!(title: "Sneaky Clone", slug: "sneaky-clone-#{SecureRandom.hex(4)}",
      status: "draft", mesh_analysis: { "duplicate_model_id" => @model.id })

    get designer_protection_path

    assert_response :success
    assert_select "#protection-fingerprints-title"
    assert_select "td", text: /#{Regexp.escape(@model.geometry_hash.truncate(30))}/
    assert_select "td", text: "1" # one blocked copy
    refute_includes response.body, "Sneaky Clone"
    refute_includes response.body, intruder.display_name
  end

  test "shows certificate-bound takedown evidence for delivered licenses only" do
    delivered = Purchase.create!(license_offer: @offer, status: "verified",
      amount_base_units: "250000", asset: X402::Requirements.usdc_asset,
      replay_key: SecureRandom.hex(32), requirements_json: { "payTo" => Rails.configuration.x.printwright.x402_pay_to })
    delivered.transition_to!(:settled)
    license = License.allocate!(delivered)
    delivered.transition_to!(:delivered)
    license.update!(hcs_sequence_number: 7)

    get designer_protection_path

    assert_response :success
    assert_select "#protection-evidence-title"
    assert_select "td", text: license.cert_id
    assert_select "a[href=?]", new_designer_takedown_packet_path(cert_id: license.cert_id)
  end

  test "never renders another studio's models, fingerprints, or licenses" do
    other = designers(:two)
    other_model = other.models3d.create!(title: "Rival Model",
      slug: "rival-model-#{SecureRandom.hex(4)}", status: "published", file_hash: "sha256:#{'c' * 64}")
    other_offer = other_model.license_offers.create!(kind: "personal", price_cents: 900)
    other_purchase = Purchase.create!(license_offer: other_offer, status: "verified",
      amount_base_units: "900000", asset: X402::Requirements.usdc_asset,
      replay_key: SecureRandom.hex(32), requirements_json: { "payTo" => Rails.configuration.x.printwright.x402_pay_to })
    other_purchase.transition_to!(:settled)
    License.allocate!(other_purchase)
    other_purchase.transition_to!(:delivered)

    get designer_protection_path

    assert_response :success
    refute_includes response.body, "Rival Model"
    refute_includes response.body, "sha256:#{'c' * 64}".truncate(30)
  end

  test "an empty studio gets an honest empty state" do
    @model.destroy
    get designer_protection_path
    assert_response :success
    assert_select ".empty-state", text: /Nothing to protect yet/
  end
end
