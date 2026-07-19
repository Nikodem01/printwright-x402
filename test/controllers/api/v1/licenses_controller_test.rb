require "test_helper"

class Api::V1::LicensesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @model = Model3d.create!(
      designer: designers(:one), title: "Policy model", slug: "policy-api-#{SecureRandom.hex(4)}",
      status: "published"
    )
  end

  test "commercial certificate answers one unit yes and three units no with terms references" do
    license = build_license("commercial_unit")

    get api_v1_license_permission_path(license.cert_id, use: "commercial_print", qty: 1)
    assert_response :success
    allowed = response.parsed_body
    assert_equal [ true, "allowed", 1 ], allowed.values_at("allowed", "reason_code", "qty")
    assert_equal 1, allowed.dig("permissions", "commercial_units", "max_units")
    assert_equal license.cert_json["terms_hash"], allowed.dig("terms", "hash")
    assert_includes allowed.dig("terms", "permissions_url"), ".json"
    assert_includes allowed["certificate_url"], license.cert_id

    get api_v1_license_permission_path(license.cert_id, use: "commercial_print", qty: 3)
    assert_response :success
    denied = response.parsed_body
    assert_equal [ false, "commercial_unit_limit", 3 ], denied.values_at("allowed", "reason_code", "qty")
  end

  test "personal certificate refuses commercial use without parsing prose" do
    license = build_license("personal")
    get api_v1_license_permission_path(license.cert_id, use: "commercial_print")

    assert_response :success
    assert_equal [ false, "commercial_use_not_granted" ],
      response.parsed_body.values_at("allowed", "reason_code")
  end

  test "invalid use and quantities fail with enumerated contracts" do
    license = build_license("personal")

    get api_v1_license_permission_path(license.cert_id, use: "invent_a_use")
    assert_response :unprocessable_content
    assert_equal "invalid_use", response.parsed_body["error"]
    assert_includes response.parsed_body["allowed_uses"], "commercial_print"

    get api_v1_license_permission_path(license.cert_id, use: "personal_print", qty: "1.5")
    assert_response :unprocessable_content
    assert_equal "invalid_quantity", response.parsed_body["error"]
  end

  test "legacy or hash-mismatched certificate refuses to invent permissions" do
    license = build_license("personal")
    license.update!(cert_json: { "terms_hash" => "sha256:legacy" })

    get api_v1_license_permission_path(license.cert_id, use: "personal_print")
    assert_response :conflict
    assert_equal "permissions_unavailable", response.parsed_body["error"]
  end

  test "sandbox receipt is never treated as a license" do
    license = build_license("personal", sandbox: true)
    get api_v1_license_permission_path(license.cert_id, use: "personal_print", qty: 1)

    assert_response :success
    assert_equal [ false, true, "sandbox_not_a_license" ],
      response.parsed_body.values_at("allowed", "sandbox", "reason_code")
  end

  private

  def build_license(kind, sandbox: false)
    offer = @model.license_offers.create!(kind: kind, price_cents: 100)
    purchase = Purchase.create!(
      license_offer: offer, status: "settled", replay_key: SecureRandom.hex(32), sandbox: sandbox
    )
    License.allocate!(purchase).tap do |license|
      license.update!(cert_json: { "terms_hash" => offer.terms_hash })
    end
  end
end
