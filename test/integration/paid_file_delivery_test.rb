require "test_helper"
require "webmock/minitest"

# The file IS the sale. Every other test in this suite checks the JSON contract;
# this one follows the URLs a paying buyer is actually handed, all the way to
# the bytes, and compares them with what the designer uploaded. A delivery that
# is shaped correctly but hands over the wrong bytes — or none — is a failed
# sale, and money never comes back.
class PaidFileDeliveryTest < ActionDispatch::IntegrationTest
  FACILITATOR = "https://facilitator.test".freeze
  PART_A = "solid part-a\nfacet normal 0 0 1\nendsolid part-a\n".freeze
  PART_B = "solid part-b\nfacet normal 0 1 0\nendsolid part-b\n".freeze

  setup do
    set_printwright(demo_hbar_price_cents: "250")
    FacilitatorClient.reset_cache!
    stub_request(:get, "#{FACILITATOR}/supported")
      .to_return(body: fixture("supported.json"), headers: { "content-type" => "application/json" })
    stub_request(:post, "#{FACILITATOR}/verify")
      .to_return(body: fixture("verify_ok.json"), headers: { "content-type" => "application/json" })
    stub_request(:post, "#{FACILITATOR}/settle")
      .to_return(body: fixture("settle_ok.json"), headers: { "content-type" => "application/json" })

    @model = Model3d.create!(
      designer: designers(:one), title: "Two-part jig", slug: "two-part-jig-#{SecureRandom.hex(4)}",
      file_hash: "sha256:#{Digest::SHA256.hexdigest(PART_A)}", status: "published"
    )
    attach(@model, PART_A, "part-a.stl", position: 0)
    attach(@model, PART_B, "part-b.stl", position: 1)
    @offer = @model.license_offers.create!(kind: "personal", price_cents: 25, currency: "HBAR", terms_md: "T.")
    @payload = JSON.parse(fixture("payment_payload.json"))
  end

  teardown { FacilitatorClient.reset_cache! }

  test "a paid purchase delivers every part, byte for byte as the designer uploaded it" do
    body = buy!

    assert_equal 2, body["files"].length
    assert_equal %w[stl stl], body["files"].map { |file| file["kind"] }
    assert_equal [ PART_A, PART_B ], body["files"].map { |file| download(file["url"]) }
  end

  test "the durable receipt returns the same bytes long after the purchase grant lapsed" do
    body = buy!
    receipt = body.fetch("receipt")

    # The response the buyer keeps says, in the payload itself, that this path
    # does not expire. Hold it to that.
    assert_nil receipt["expires_at"]

    travel DownloadGrant::LIFETIME + 1.day do
      body["files"].each { |file| assert_equal "grant_expired", error_from(file["url"]) }

      get receipt.fetch("files_url"), params: { token: receipt.fetch("token") }
      assert_response :success
      assert_equal [ PART_A, PART_B ], response.parsed_body["files"].map { |file| download(file["url"]) }

      # And the plain human link, per part, without reading any JSON.
      assert_equal PART_A, download(receipt.fetch("download_url") + "?token=#{receipt.fetch('token')}")
      assert_equal PART_B, download(receipt.fetch("download_url") + "?token=#{receipt.fetch('token')}&f=1")
    end
  end

  test "a settled purchase whose file is missing fails loudly and stays claimable" do
    @model.printable_files.each { |file| file.file.purge }

    get download_path, headers: payment_headers

    # Money moved and we do not refund, so this must not be a 200 with an empty
    # files array — and the purchase must stay in a state the same signed
    # payment can retry once the file is back.
    assert_response :service_unavailable
    body = response.parsed_body
    assert_equal "no_deliverable_file", body["error"]
    assert body["recoverable"]
    assert_equal "0.0.7162784@1784125705.137810120", body["transaction_id"]

    purchase = Purchase.sole
    assert_equal "settled", purchase.status
    assert_equal "no_deliverable_file", purchase.error_reason
    assert purchase.license.present?, "the license is owed even though the bytes are not there yet"

    attach(@model, PART_A, "part-a.stl", position: 0)
    get download_path, headers: payment_headers

    assert_response :success
    assert_equal "delivered", purchase.reload.status
    assert_equal [ PART_A ], response.parsed_body["files"].map { |file| download(file["url"]) }
  end

  test "a detached part 404s instead of silently serving its neighbour's geometry" do
    body = buy!
    @model.printable_files.first.file.purge

    assert_equal "file_not_found", error_from(body["files"].first["url"])
    assert_equal PART_B, download(body["files"].second["url"])
  end

  test "a buyer keeps access when the designer publishes a new version" do
    body = buy!
    updates = body.fetch("model_updates")
    revised = "solid part-a-v2\nendsolid part-a-v2\n"
    publish_version!(revised)

    get updates.fetch("url"), headers: { "Authorization" => "Bearer #{updates.fetch('receipt_token')}" }
    assert_response :success
    assert_equal 2, response.parsed_body["version"]

    get updates.fetch("download_url"), headers: { "Authorization" => "Bearer #{updates.fetch('receipt_token')}" }
    assert_equal revised, follow_to_bytes

    # The original certified bundle stays reachable: an update adds a version,
    # it never withdraws what was paid for.
    receipt = body.fetch("receipt")
    get receipt.fetch("files_url"), params: { token: receipt.fetch("token") }
    assert_equal [ PART_A, PART_B ], response.parsed_body["files"].map { |file| download(file["url"]) }
  end

  private

  def buy!
    get download_path, headers: payment_headers
    assert_response :success
    response.parsed_body
  end

  def publish_version!(bytes)
    version = @model.model_versions.create!(
      number: 2, file_kind: "stl", changelog: "Tighter tolerance.",
      file_hash: "sha256:#{Digest::SHA256.hexdigest(bytes)}",
      changelog_hash: "sha256:#{Digest::SHA256.hexdigest('Tighter tolerance.')}",
      published_at: Time.current, mesh_analysis_status: "passed"
    )
    version.file.attach(io: StringIO.new(bytes), filename: "part-a-v2.stl", content_type: "model/stl")
    part = version.version_files.create!(kind: "stl", position: 0, file_hash: version.file_hash)
    part.file.attach(io: StringIO.new(bytes), filename: "part-a-v2.stl", content_type: "model/stl")
    version
  end

  def attach(model, bytes, filename, position:)
    file = model.model_files.create!(kind: "stl", position: position)
    file.file.attach(io: StringIO.new(bytes), filename: filename, content_type: "model/stl")
    model.association(:model_files).reset
    file
  end

  # Follows the grant redirect through Active Storage to the stored bytes.
  def download(url)
    get url
    follow_to_bytes
  end

  def follow_to_bytes
    assert_response :redirect
    follow_redirect! while response.redirect?
    response.body
  end

  def error_from(url)
    get url
    response.parsed_body["error"]
  end

  def download_path = "/api/v1/models/#{@model.id}/download"
  def fixture(name) = file_fixture("x402/#{name}").read
  def payment_headers = { "PAYMENT-SIGNATURE" => Base64.strict_encode64(JSON.generate(@payload)) }
end
