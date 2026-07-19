require "test_helper"
require_relative "../test_helpers/mesh_test_helper"

class AnalyzeModelMeshJobTest < ActiveJob::TestCase
  include MeshTestHelper

  test "marks a valid draft passed" do
    model = designers(:one).models3d.create!(title: "Valid upload", slug: "valid-upload")
    attach_stl(model, box_stl)

    AnalyzeModelMeshJob.perform_now(model.id)

    assert_equal "passed", model.reload.mesh_analysis_status
    assert_empty model.mesh_analysis_errors
    assert_match(/\Asha256:/, model.geometry_hash)
  end

  test "marks a changed-byte copy of published geometry as a duplicate" do
    existing = designers(:one).models3d.create!(
      title: "Original box", slug: "original-box", status: "published"
    )
    attach_stl(existing, box_stl, filename: "original.stl")
    AnalyzeModelMeshJob.perform_now(existing.id)
    existing.reload
    existing.update!(file_hash: existing.mesh_analysis_digest)

    copy = designers(:two).models3d.create!(title: "Copied box", slug: "copied-box")
    attach_stl(copy, box_stl(offset: [ 8.0, 3.0, -2.0 ], reverse: true), filename: "copy.stl")

    AnalyzeModelMeshJob.perform_now(copy.id)

    assert_not_equal existing.file_hash, copy.reload.mesh_analysis_digest
    assert_equal existing.geometry_hash, copy.geometry_hash
    assert_equal "failed", copy.mesh_analysis_status
    assert_includes copy.mesh_analysis_errors.join(" "), "matches existing published model “Original box”"
  end
end
