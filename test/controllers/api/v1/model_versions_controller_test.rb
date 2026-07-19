require "test_helper"

class Api::V1::ModelVersionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @model = Model3d.create!(designer: designers(:one), title: "Paid update", slug: "paid-update",
      status: "published", file_hash: "sha256:#{'a' * 64}")
    original = @model.model_files.create!(kind: "stl")
    original.file.attach(io: StringIO.new("solid original\nendsolid original\n"),
      filename: "original.stl", content_type: "model/stl")
    offer = @model.license_offers.create!(kind: "personal", price_cents: 25, terms_md: "T.")
    purchase = Purchase.create!(license_offer: offer, status: "settled", replay_key: SecureRandom.hex(32),
      payment_tx_id: "0.0.1@1.2")
    @license = License.allocate!(purchase)
    @license.update!(cert_json: Certificates::Builder.call(@license))
    purchase.transition_to!(:delivered)
    @token = @license.signed_id(purpose: "model-updates")
  end

  test "paid receipt reports and downloads the latest published file" do
    version = @model.model_versions.create!(number: 2, file_kind: "stl",
      file_hash: "sha256:#{'b' * 64}", changelog: "Stronger hinge.",
      changelog_hash: "sha256:#{Digest::SHA256.hexdigest('Stronger hinge.')}",
      event_json: { "schema" => "pwv-1" }, hcs_topic_id: "0.0.9585069",
      hcs_sequence_number: 61, published_at: Time.current)
    version.file.attach(io: StringIO.new("solid latest\nendsolid latest\n"),
      filename: "latest.stl", content_type: "model/stl")

    get api_v1_license_latest_version_path(@license.cert_id), headers: bearer(@token)
    assert_response :success
    assert_equal [ 2, version.file_hash, @license.cert_json["model_hash"], 61 ],
      response.parsed_body.values_at("version", "file_hash", "original_certificate_hash", "hcs_sequence_number")
    assert_equal "Stronger hinge.", response.parsed_body["changelog"]
    assert_equal version.changelog_hash, response.parsed_body["changelog_hash"]
    assert_includes response.parsed_body["hcs_mirror_url"], "/topics/0.0.9585069/messages/61"

    get api_v1_license_latest_version_file_path(@license.cert_id), headers: bearer(@token)
    assert_response :redirect
    assert_includes response.location, "/rails/active_storage/blobs/redirect/"
  end

  test "without an update, version 1 remains downloadable and matches the certificate" do
    get api_v1_license_latest_version_path(@license.cert_id), headers: bearer(@token)
    assert_response :success
    assert_equal [ 1, @license.cert_json["model_hash"], @license.cert_json["model_hash"] ],
      response.parsed_body.values_at("version", "file_hash", "original_certificate_hash")

    get api_v1_license_latest_version_file_path(@license.cert_id), headers: bearer(@token)
    assert_response :redirect
  end

  test "receipt is required, license-scoped, delivered, and never available to sandbox" do
    get api_v1_license_latest_version_path(@license.cert_id)
    assert_response :unauthorized
    get api_v1_license_latest_version_path(@license.cert_id), headers: { "Authorization" => "Basic #{@token}" }
    assert_response :unauthorized
    get api_v1_license_latest_version_path(@license.cert_id), headers: bearer("forged")
    assert_response :not_found

    other_purchase = @license.purchase.dup
    other_purchase.replay_key = SecureRandom.hex(32)
    other_purchase.payment_tx_id = "0.0.1@2.3"
    other_purchase.save!
    other = License.allocate!(other_purchase)
    get api_v1_license_latest_version_path(other.cert_id), headers: bearer(@token)
    assert_response :not_found

    @license.purchase.update!(sandbox: true)
    get api_v1_license_latest_version_path(@license.cert_id), headers: bearer(@token)
    assert_response :forbidden
  end

  private

  def bearer(token)
    { "Authorization" => "Bearer #{token}" }
  end
end
