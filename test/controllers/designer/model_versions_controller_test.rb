require "test_helper"

class Designer::ModelVersionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @model = Model3d.create!(designer: designers(:one), title: "Clamp", slug: "update-clamp",
      status: "published", file_hash: "sha256:#{'a' * 64}")
    sign_in_as designers(:one)
  end

  test "designer publishes a validated version without rewriting the original hash" do
    original_hash = @model.file_hash
    offer = @model.license_offers.create!(kind: "personal", price_cents: 25, terms_md: "T.")
    purchase = Purchase.create!(license_offer: offer, status: "settled", replay_key: SecureRandom.hex(32),
      payment_tx_id: "0.0.1@1.2")
    license = License.allocate!(purchase)
    original_certificate = Certificates::Builder.call(license)
    file = fixture_file_upload(Rails.root.join("db/seed_assets/calibration-cube.stl"), "model/stl")

    assert_enqueued_with(job: ModelVersionAnchorJob) do
      post designer_model_versions_path(@model), params: {
        model_version: { changelog: "Strengthened the hinge.", file: file }
      }
    end

    assert_redirected_to edit_designer_model_path(@model)
    version = @model.model_versions.sole
    assert_equal [ 2, "stl", "Strengthened the hinge." ],
      [ version.number, version.file_kind, version.changelog ]
    assert_match(/\Asha256:[0-9a-f]{64}\z/, version.file_hash)
    assert_predicate version.file, :attached?
    assert_equal original_hash, @model.reload.file_hash
    assert_equal original_hash, original_certificate["model_hash"]
    assert_equal original_certificate, Certificates::Builder.call(license)
  end

  test "published bundle cannot be replaced through the original upload flow" do
    original_hash = @model.file_hash
    file = fixture_file_upload(Rails.root.join("db/seed_assets/calibration-cube.stl"), "model/stl")

    patch designer_model_path(@model), params: { model3d: {
      title: @model.title, printable_files: [ file ]
    } }

    assert_redirected_to edit_designer_model_path(@model)
    assert_empty @model.reload.model_files
    assert_equal original_hash, @model.file_hash
    follow_redirect!
    assert_match(/certified bundle is frozen/, response.body)
  end

  test "another designer cannot version the model" do
    sign_in_as designers(:two)
    file = fixture_file_upload(Rails.root.join("db/seed_assets/calibration-cube.stl"), "model/stl")
    post designer_model_versions_path(@model), params: {
      model_version: { changelog: "Not mine.", file: file }
    }
    assert_response :not_found
    assert_empty @model.model_versions
  end

  test "drafts and invalid uploads are rejected" do
    @model.update!(status: "draft")
    bad = Rack::Test::UploadedFile.new(StringIO.new("not an stl"), "model/stl", original_filename: "bad.stl")
    post designer_model_versions_path(@model), params: {
      model_version: { changelog: "No.", file: bad }
    }
    assert_redirected_to edit_designer_model_path(@model)
    assert_empty @model.model_versions
  end
end
