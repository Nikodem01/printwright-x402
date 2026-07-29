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
    # A single-file upload still creates exactly one version_file mirroring
    # the primary — the same invariant a migration backfills for versions
    # that predate multi-file bundles.
    assert_equal 1, version.version_files.count
    assert_equal [ version.file_kind, version.file_hash ],
      [ version.version_files.sole.kind, version.version_files.sole.file_hash ]
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
    # Mirror what #create actually persists: every version carries its bundle,
    # even a one-file one. Without this the version is in a state no upload can
    # produce, and the job is asked to judge a bundle it was never given.
    version.version_files.create!(position: 0, kind: "step", file_hash: version.file_hash)
      .file.attach(version.file.blob)

    assert_enqueued_with(job: ModelVersionAnchorJob) do
      AnalyzeModelVersionMeshJob.perform_now(version.id)
    end

    assert_equal "skipped", version.reload.mesh_analysis_status
    assert_predicate version, :deliverable?
  end

  test "a multi-file bundle creates ordered version files with per-file hashes and a shared primary" do
    @model.update!(status: "paused")
    original_hash = @model.file_hash
    cube = fixture_file_upload(Rails.root.join("db/seed_assets/calibration-cube.stl"), "model/stl")
    step = Rack::Test::UploadedFile.new(StringIO.new("ISO-10303-21;\nHEADER;"), "model/step",
      original_filename: "source.step")

    assert_enqueued_with(job: AnalyzeModelVersionMeshJob) do
      post designer_model_versions_path(@model), params: {
        model_version: { changelog: "STL print file plus CAD source.", files: [ cube, step ] }
      }
    end

    assert_redirected_to edit_designer_model_path(@model)
    version = @model.model_versions.sole
    files = version.version_files.ordered
    assert_equal 2, files.size
    assert_equal [ 0, 1 ], files.map(&:position)
    assert_equal %w[stl step], files.map(&:kind)
    assert_equal [ version.file_kind, version.file_hash ], [ files.first.kind, files.first.file_hash ]
    files.each { |f| assert_predicate f.file, :attached? }
    assert_predicate version.file, :attached?
    assert_equal version.file.blob, files.first.file.blob
    assert_equal original_hash, @model.reload.file_hash
  end

  test "a large bundle publishes and anchors — the file count is the designer's call" do
    @model.update!(status: "paused")
    # A twelve-part assembly: the print file plus eleven CAD sources. The count
    # is not capped; the bundle only has to carry something we can check.
    files = [ fixture_file_upload(Rails.root.join("db/seed_assets/calibration-cube.stl"), "model/stl") ]
    files += Array.new(11) do |index|
      Rack::Test::UploadedFile.new(
        StringIO.new("ISO-10303-21;\nHEADER;part #{index}"), "model/step",
        original_filename: "part-#{index}.step"
      )
    end

    assert_enqueued_with(job: AnalyzeModelVersionMeshJob) do
      post designer_model_versions_path(@model), params: {
        model_version: { changelog: "Twelve-part assembly.", files: files }
      }
    end

    version = @model.model_versions.sole
    assert_equal 12, version.version_files.count
    # The provenance record commits to the list instead of carrying it, so a
    # twelve-part model anchors in exactly one message like any other.
    assert_operator version.anchor_payload.to_json.bytesize, :<, 1024
    assert_equal version.files_hash, version.anchor_payload["files_hash"]
    assert_equal 12, version.anchor_payload["file_count"]
  end

  test "an invalid file anywhere in the bundle rejects the whole submission" do
    @model.update!(status: "published")
    good = fixture_file_upload(Rails.root.join("db/seed_assets/calibration-cube.stl"), "model/stl")
    bad = Rack::Test::UploadedFile.new(StringIO.new("not an stl"), "model/stl", original_filename: "bad.stl")

    post designer_model_versions_path(@model), params: {
      model_version: { changelog: "Bundle with a bad part.", files: [ good, bad ] }
    }

    assert_redirected_to edit_designer_model_path(@model)
    assert_empty @model.model_versions
    follow_redirect!
    assert_match(/Rejected:/, response.body)
  end

  test "an all-STL bundle is analyzed as a whole and anchors once every file passes" do
    @model.update!(status: "paused")
    first = fixture_file_upload(Rails.root.join("db/seed_assets/calibration-cube.stl"), "model/stl")
    second = fixture_file_upload(Rails.root.join("db/seed_assets/cable-clip.stl"), "model/stl")

    assert_enqueued_with(job: AnalyzeModelVersionMeshJob) do
      post designer_model_versions_path(@model), params: {
        model_version: { changelog: "Two-part bundle.", files: [ first, second ] }
      }
    end
    version = @model.model_versions.sole

    assert_enqueued_with(job: ModelVersionAnchorJob) do
      perform_enqueued_jobs(only: AnalyzeModelVersionMeshJob) do
        AnalyzeModelVersionMeshJob.perform_now(version.id)
      end
    end
    assert_equal "passed", version.reload.mesh_analysis_status
    assert_predicate version, :deliverable?
  end

  # Companion-only: buyers receive a version as their model update, so it must
  # carry at least one file we can actually geometry-check.
  test "a version cannot ship the same file twice under different names" do
    @model.update!(status: "paused")
    bytes = Rails.root.join("db/seed_assets/calibration-cube.stl").binread
    first = fixture_file_upload(Rails.root.join("db/seed_assets/calibration-cube.stl"), "model/stl")
    copy = Rack::Test::UploadedFile.new(StringIO.new(bytes), "model/stl", original_filename: "cube-copy.stl")

    post designer_model_versions_path(@model), params: {
      model_version: { changelog: "Duplicated part.", files: [ first, copy ] }
    }

    assert_redirected_to edit_designer_model_path(@model)
    assert_empty @model.model_versions
    follow_redirect!
    assert_match(/cube-copy\.stl/, response.body)
  end

  test "a version made only of unreadable formats is refused at the door" do
    @model.update!(status: "paused")
    step = Rack::Test::UploadedFile.new(StringIO.new("ISO-10303-21;\nHEADER;"), "model/step",
      original_filename: "source.step")

    post designer_model_versions_path(@model), params: {
      model_version: { changelog: "CAD source only.", files: [ step ] }
    }

    assert_redirected_to edit_designer_model_path(@model)
    assert_empty @model.model_versions
    follow_redirect!
    assert_match(/STL or 3MF/, response.body)
    assert_match(/source\.step/, response.body)
  end

  test "a CAD companion file does not exempt the printable files shipping beside it" do
    @model.update!(status: "paused")
    stl = fixture_file_upload(Rails.root.join("db/seed_assets/calibration-cube.stl"), "model/stl")
    step = Rack::Test::UploadedFile.new(StringIO.new("ISO-10303-21;\nHEADER;"), "model/step",
      original_filename: "source.step")

    post designer_model_versions_path(@model), params: {
      model_version: { changelog: "STL print file plus CAD source.", files: [ stl, step ] }
    }
    version = @model.model_versions.sole

    assert_enqueued_with(job: ModelVersionAnchorJob) do
      AnalyzeModelVersionMeshJob.perform_now(version.id)
    end

    # The STL is inspected on its own merits and the verdict is a real one —
    # the STEP file no longer sends the whole bundle down the skipped branch.
    assert_equal "passed", version.reload.mesh_analysis_status
    assert_predicate version, :deliverable?
    assert_equal %w[stl step], version.version_files.ordered.map(&:kind)
    assert_equal [ "calibration-cube.stl" ],
      version.mesh_analysis.fetch("files").map { |report| report.fetch("filename") }
  end

  test "a failing analyzer withholds a multi-file bundle and never anchors it" do
    @model.update!(status: "published")
    first = fixture_file_upload(Rails.root.join("db/seed_assets/calibration-cube.stl"), "model/stl")
    second = fixture_file_upload(Rails.root.join("db/seed_assets/cable-clip.stl"), "model/stl")
    post designer_model_versions_path(@model), params: {
      model_version: { changelog: "Broke the bundle.", files: [ first, second ] }
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
    assert_not version.anchored?
  ensure
    singleton&.define_method(:call, original) if original
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
