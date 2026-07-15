require "test_helper"

class Api::V1::FilesControllerTest < ActionDispatch::IntegrationTest
  setup do
    model = Model3d.create!(
      designer: designers(:one), title: "F", slug: "f-#{SecureRandom.hex(4)}", status: "published"
    )
    stl = model.model_files.create!(kind: "stl", position: 0)
    stl.file.attach(io: StringIO.new("solid f\nendsolid f\n"), filename: "f.stl", content_type: "model/stl")
    offer = model.license_offers.create!(kind: "personal", price_cents: 100)
    purchase = Purchase.create!(license_offer: offer, status: "settled", replay_key: SecureRandom.hex(32))
    @license = License.allocate!(purchase)
    purchase.transition_to!(:delivered)
    @grant = DownloadGrant.issue!(@license)
  end

  test "usable grant redirects to the blob and counts the use" do
    get api_v1_file_url(@grant.token)
    assert_response :redirect
    assert_includes response.location, "rails/active_storage"
    assert_equal 1, @grant.reload.uses
  end

  test "expired grant is 410" do
    travel 25.hours do
      get api_v1_file_url(@grant.token)
      assert_response :gone
      assert_equal "grant_expired", response.parsed_body["error"]
    end
  end

  test "exhausted grant is 410" do
    @grant.update!(uses: @grant.max_uses)
    get api_v1_file_url(@grant.token)
    assert_response :gone
  end

  test "unknown token is 404" do
    get api_v1_file_url("nope")
    assert_response :not_found
  end
end
