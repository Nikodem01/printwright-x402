require "test_helper"
require "webmock/minitest"

# The published error contract (docs "Error contract" table and openapi.json)
# promises 503 facilitator_unavailable + retry_after when the facilitator is
# down or its breaker is open. Verify/settle honour that, but building the 402
# challenge also calls the facilitator — for the fee payer — and that path had
# no handler, so a facilitator outage answered the very first quote with an
# unhandled HTML 500 instead of the documented JSON.
class Api::V1::FacilitatorOutageTest < ActionDispatch::IntegrationTest
  FACILITATOR = "https://facilitator.test".freeze

  setup do
    FacilitatorClient.reset_cache!
    stub_request(:get, "#{FACILITATOR}/supported").to_timeout

    @model = Model3d.create!(
      designer: designers(:one), title: "Outage Probe", slug: "outage-probe",
      file_hash: "sha256:#{Digest::SHA256.hexdigest('outage')}", status: "published"
    )
    stl = @model.model_files.create!(kind: "stl", position: 0)
    stl.file.attach(io: StringIO.new("solid t\nendsolid t\n"), filename: "t.stl",
      content_type: "model/stl")
    @offer = @model.license_offers.create!(kind: "personal", price_cents: 25, terms_md: "T.")
  end

  teardown { FacilitatorClient.reset_cache! }

  test "an unpaid download quote answers the documented 503 when the facilitator is down" do
    get "/api/v1/models/#{@model.id}/download", params: { license: "personal" }

    assert_response :service_unavailable
    body = JSON.parse(response.body)
    assert_equal "facilitator_unavailable", body["error"]
    assert_equal 5, body["retry_after"]
  end

  test "a batch quote answers the documented 503 when the facilitator is down" do
    post "/api/v1/batches", params: { items: [ { model_id: @model.id, license: "personal" } ] },
      as: :json

    assert_response :service_unavailable
    assert_equal "facilitator_unavailable", JSON.parse(response.body)["error"]
  end
end
