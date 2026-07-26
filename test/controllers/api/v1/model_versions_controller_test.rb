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

  test "paid receipt reports and downloads the latest deliverable file" do
    version = deliverable_version(number: 2, changelog: "Stronger hinge.", sequence: 61)

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

  test "a pending or failed version is withheld; the buyer keeps the previous deliverable bundle" do
    passed = deliverable_version(number: 2, changelog: "Good update.", sequence: 61)
    %w[pending failed].each do |status|
      newer = @model.model_versions.create!(number: 3, file_kind: "stl",
        file_hash: "sha256:#{'d' * 64}", changelog: "Not ready.",
        changelog_hash: "sha256:#{Digest::SHA256.hexdigest('Not ready.')}",
        published_at: Time.current, mesh_analysis_status: status)
      newer.file.attach(io: StringIO.new("solid pending\nendsolid pending\n"),
        filename: "pending.stl", content_type: "model/stl")

      get api_v1_license_latest_version_path(@license.cert_id), headers: bearer(@token)
      assert_response :success
      assert_equal passed.number, response.parsed_body["version"],
        "buyer must keep v2 while v3 is #{status}"

      newer.destroy
    end
  end

  test "when the only version is not deliverable the buyer keeps the original certified bundle" do
    pending = @model.model_versions.create!(number: 2, file_kind: "stl",
      file_hash: "sha256:#{'d' * 64}", changelog: "Validating.",
      changelog_hash: "sha256:#{Digest::SHA256.hexdigest('Validating.')}",
      published_at: Time.current, mesh_analysis_status: "pending")
    pending.file.attach(io: StringIO.new("solid pending\nendsolid pending\n"),
      filename: "pending.stl", content_type: "model/stl")

    get api_v1_license_latest_version_path(@license.cert_id), headers: bearer(@token)
    assert_response :success
    assert_equal 1, response.parsed_body["version"]
    assert_equal @license.cert_json["model_hash"], response.parsed_body["file_hash"]
  end

  test "without an update, version 1 remains downloadable and matches the certificate" do
    get api_v1_license_latest_version_path(@license.cert_id), headers: bearer(@token)
    assert_response :success
    assert_equal [ 1, @license.cert_json["model_hash"], @license.cert_json["model_hash"] ],
      response.parsed_body.values_at("version", "file_hash", "original_certificate_hash")
    assert_equal [ { "kind" => "stl", "file_hash" => @license.cert_json["model_hash"],
      "download_url" => api_v1_license_latest_version_file_url(@license.cert_id, f: 0) } ],
      response.parsed_body["files"]

    get api_v1_license_latest_version_file_path(@license.cert_id), headers: bearer(@token)
    assert_response :redirect
    assert_includes response.location, "original.stl"

    get api_v1_license_latest_version_file_path(@license.cert_id, f: 5), headers: bearer(@token)
    assert_response :not_found
  end

  test "a multi-file version reports its bundle and serves each file by index" do
    version = deliverable_version(number: 2, changelog: "Two-part bundle.", sequence: 61)
    second = version.version_files.create!(position: 1, kind: "stl", file_hash: "sha256:#{'c' * 64}")
    second.file.attach(io: StringIO.new("solid part-b\nendsolid part-b\n"),
      filename: "part-b.stl", content_type: "model/stl")

    get api_v1_license_latest_version_path(@license.cert_id), headers: bearer(@token)
    assert_response :success
    body = response.parsed_body
    assert_equal [ version.file_hash, version.file_kind, 2 ],
      [ body["file_hash"], body["file_kind"], body["files"].length ]
    assert_not_includes body["download_url"], "f="
    assert_equal %w[stl stl], body["files"].map { |f| f["kind"] }
    assert_equal [ version.file_hash, "sha256:#{'c' * 64}" ], body["files"].map { |f| f["file_hash"] }
    assert_includes body["files"][0]["download_url"], "f=0"
    assert_includes body["files"][1]["download_url"], "f=1"

    get api_v1_license_latest_version_file_path(@license.cert_id), headers: bearer(@token)
    assert_includes response.location, "latest.stl"

    get api_v1_license_latest_version_file_path(@license.cert_id, f: 0), headers: bearer(@token)
    assert_includes response.location, "latest.stl"

    get api_v1_license_latest_version_file_path(@license.cert_id, f: 1), headers: bearer(@token)
    assert_includes response.location, "part-b.stl"

    %w[5 -1 abc].each do |bad|
      get api_v1_license_latest_version_file_path(@license.cert_id, f: bad), headers: bearer(@token)
      assert_response :not_found
    end
  end

  # The controller documents how to recompute files_hash from the served `files`
  # list. A third party has only that comment and this response, so run the
  # recipe exactly as written and require it to land on both the served value and
  # the value anchored on HCS. The rename is the whole trap: the manifest that is
  # hashed keys the digest `hash`, while `files` serves it as `file_hash`.
  test "the documented recipe recomputes files_hash from the served bundle" do
    version = deliverable_version(number: 2, changelog: "Two-part bundle.", sequence: 61)
    second = version.version_files.create!(position: 1, kind: "stl", file_hash: "sha256:#{'c' * 64}")
    second.file.attach(io: StringIO.new("solid part-b\nendsolid part-b\n"),
      filename: "part-b.stl", content_type: "model/stl")

    get api_v1_license_latest_version_path(@license.cert_id), headers: bearer(@token)
    assert_response :success
    body = response.parsed_body

    manifest = body["files"].map { |f| { "kind" => f["kind"], "hash" => f["file_hash"] } }
    recomputed = "sha256:#{Digest::SHA256.hexdigest(manifest.to_json_c14n)}"

    assert_equal body["files_hash"], recomputed
    assert_equal version.anchor_payload["files_hash"], recomputed

    # Passing the served entries through unmapped is the reading the old wording
    # invited; it must not be mistaken for the real digest.
    naive = "sha256:#{Digest::SHA256.hexdigest(body['files'].map { |f| f.except('download_url') }.to_json_c14n)}"
    assert_not_equal body["files_hash"], naive
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

  def deliverable_version(number:, changelog:, sequence:)
    version = @model.model_versions.create!(number: number, file_kind: "stl",
      file_hash: "sha256:#{'b' * 64}", changelog: changelog,
      changelog_hash: "sha256:#{Digest::SHA256.hexdigest(changelog)}",
      event_json: { "schema" => "pwv-1" }, hcs_topic_id: "0.0.9585069",
      hcs_sequence_number: sequence, published_at: Time.current,
      mesh_analysis_status: "passed")
    version.file.attach(io: StringIO.new("solid latest\nendsolid latest\n"),
      filename: "latest.stl", content_type: "model/stl")
    # Mirrors the primary file as a version_file, exactly as the controller
    # and the backfill migration do for every real version.
    version_file = version.version_files.create!(position: 0, kind: version.file_kind, file_hash: version.file_hash)
    version_file.file.attach(version.file.blob)
    version
  end

  def bearer(token)
    { "Authorization" => "Bearer #{token}" }
  end
end
