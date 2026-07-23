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
    @model.update!(status: "paused")

    # Upload now queues validation (not an immediate anchor); the version is
    # not deliverable until it passes.
    assert_enqueued_with(job: AnalyzeModelVersionMeshJob) do
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
    assert_equal "pending", version.mesh_analysis_status
    assert_not version.deliverable?
    assert_equal original_hash, @model.reload.file_hash
    assert_predicate @model, :paused?
    assert_equal original_hash, original_certificate["model_hash"]
    assert_equal original_hash, Certificates::Builder.call(license)["model_hash"]

    # Validation passing makes it deliverable and anchors it; a real cube passes.
    assert_enqueued_with(job: ModelVersionAnchorJob) do
      perform_enqueued_jobs(only: AnalyzeModelVersionMeshJob) do
        AnalyzeModelVersionMeshJob.perform_now(version.id)
      end
    end
    assert_equal "passed", version.reload.mesh_analysis_status
    assert_predicate version, :deliverable?
    assert_equal original_hash, @model.reload.file_hash
  end

  test "a version that fails mesh analysis is withheld from buyers and never anchored" do
    file = fixture_file_upload(Rails.root.join("db/seed_assets/calibration-cube.stl"), "model/stl")
    @model.update!(status: "published")
    post designer_model_versions_path(@model), params: {
      model_version: { changelog: "Broke the mesh.", file: file }
    }
    version = @model.model_versions.sole

    singleton = MeshAnalysis::Analyzer.singleton_class
    original = MeshAnalysis::Analyzer.method(:call)
    singleton.define_method(:call) do |_files|
      MeshAnalysis::Analyzer::Result.new(digest: "sha256:#{'e' * 64}", geometry_hash: nil,
        errors: [ "wall too thin" ], files: [])
    end

    assert_no_enqueued_jobs(only: ModelVersionAnchorJob) do
      AnalyzeModelVersionMeshJob.perform_now(version.id)
    end

    assert_equal "failed", version.reload.mesh_analysis_status
    assert_not version.deliverable?
    assert_equal [ "wall too thin" ], version.mesh_analysis_errors
    assert_not version.anchored?
  ensure
    singleton&.define_method(:call, original) if original
  end

  test "a STEP version cannot be mesh-validated so it is accepted and delivered as before" do
    version = @model.model_versions.create!(number: 2, file_kind: "step",
      file_hash: "sha256:#{'b' * 64}", changelog: "CAD source refresh.",
      changelog_hash: "sha256:#{'c' * 64}", published_at: Time.current)
    version.file.attach(io: StringIO.new("STEP-BYTES"), filename: "part.step", content_type: "model/step")

    assert_enqueued_with(job: ModelVersionAnchorJob) do
      AnalyzeModelVersionMeshJob.perform_now(version.id)
    end

    assert_equal "skipped", version.reload.mesh_analysis_status
    assert_predicate version, :deliverable?
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
