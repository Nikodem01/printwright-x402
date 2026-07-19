require "test_helper"
require "webmock/minitest"

class ModelVersionAnchorJobTest < ActiveJob::TestCase
  SIDECAR = "http://localhost:4021".freeze

  setup do
    ENV["SIDECAR_TOKEN"] = "test-sidecar-token"
    ENV["HEDERA_SIDECAR_URL"] = SIDECAR
    model = Model3d.create!(designer: designers(:one), title: "V", slug: "v-#{SecureRandom.hex(4)}",
      status: "published", file_hash: "sha256:#{'a' * 64}")
    @version = model.model_versions.create!(number: 2, file_kind: "stl",
      file_hash: "sha256:#{'b' * 64}", changelog: "Stronger tab.",
      changelog_hash: "sha256:#{Digest::SHA256.hexdigest('Stronger tab.')}", published_at: Time.current)
  end

  test "submits the frozen update event and records its HCS position" do
    stub_request(:post, "#{SIDECAR}/submit-version")
      .to_return(body: JSON.generate(topicId: "0.0.9585069", sequenceNumber: 61,
        transactionId: "0.0.1@2.3"), headers: { "content-type" => "application/json" })

    ModelVersionAnchorJob.perform_now(@version.id)

    @version.reload
    assert_equal [ "0.0.9585069", 61, "0.0.1@2.3" ],
      [ @version.hcs_topic_id, @version.hcs_sequence_number, @version.hcs_transaction_id ]
    assert_equal "pwv-1", @version.event_json["schema"]
    assert_requested(:post, "#{SIDECAR}/submit-version") do |request|
      JSON.parse(request.body)["version"] == @version.event_json
    end
  end

  test "an anchored version is idempotent" do
    @version.update!(hcs_topic_id: "0.0.9585069", hcs_sequence_number: 61)
    ModelVersionAnchorJob.perform_now(@version.id)
    assert_not_requested :post, "#{SIDECAR}/submit-version"
  end
end
