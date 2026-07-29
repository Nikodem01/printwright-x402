require "test_helper"
require_relative "../test_helpers/mesh_test_helper"

class AnalyzeModelVersionMeshJobTest < ActiveSupport::TestCase
  include MeshTestHelper

  setup do
    @model = Model3d.create!(designer: designers(:one), title: "Bracket", slug: "analyzed-bracket",
      status: "published", file_hash: "sha256:#{'a' * 64}")
  end

  # A file the analyzer cannot read speaks only for itself. Before this, one
  # STEP file sent the whole bundle down the "skipped" branch, so a broken STL
  # beside it reached buyers unchecked.
  test "a broken STL still fails when an unreadable companion file sits beside it" do
    version = build_version(
      [ [ "broken.stl", "stl", open_box_stl ], [ "source.step", "step", "ISO-10303-21;\nHEADER;" ] ]
    )

    AnalyzeModelVersionMeshJob.perform_now(version.id)

    assert_equal "failed", version.reload.mesh_analysis_status
    assert_not_predicate version, :deliverable?
    assert version.mesh_analysis_errors.any? { |error| error.match?(/broken\.stl: is open/) },
      "expected the broken STL to be named: #{version.mesh_analysis_errors.inspect}"
  end

  test "a sound STL passes with an unreadable companion file beside it" do
    version = build_version(
      [ [ "cube.stl", "stl", box_stl ], [ "source.step", "step", "ISO-10303-21;\nHEADER;" ] ]
    )

    AnalyzeModelVersionMeshJob.perform_now(version.id)

    assert_equal "passed", version.reload.mesh_analysis_status
    assert_predicate version, :deliverable?
    assert_empty version.mesh_analysis_errors
  end

  # The report covers the files that were actually inspected, so a designer can
  # see which file the verdict came from.
  test "the recorded report names only the files that could be analyzed" do
    version = build_version(
      [ [ "cube.stl", "stl", box_stl ], [ "source.step", "step", "ISO-10303-21;\nHEADER;" ] ]
    )

    AnalyzeModelVersionMeshJob.perform_now(version.id)

    reports = version.reload.mesh_analysis.fetch("files")
    assert_equal [ "cube.stl" ], reports.map { |report| report.fetch("filename") }
  end

  # Unchanged behaviour: with nothing analyzable in the bundle there is no
  # geometry verdict to give, so it stays "skipped" as before. New uploads of
  # this shape are refused at the door instead (companion-only rule).
  test "a bundle with no analyzable file is still skipped" do
    version = build_version([ [ "part.step", "step", "ISO-10303-21;\nHEADER;" ] ], file_kind: "step")

    AnalyzeModelVersionMeshJob.perform_now(version.id)

    assert_equal "skipped", version.reload.mesh_analysis_status
    assert_predicate version, :deliverable?
  end

  test "an all-STL bundle is unaffected" do
    version = build_version([ [ "a.stl", "stl", box_stl ], [ "b.stl", "stl", box_stl ] ])

    AnalyzeModelVersionMeshJob.perform_now(version.id)

    assert_equal "passed", version.reload.mesh_analysis_status
  end

  # `skipped` counts as deliverable, so a bundle the job cannot see must not
  # take that branch — it stays pending and is withheld instead.
  test "a version with no bundle files is withheld rather than passed as skipped" do
    version = build_version([ [ "cube.stl", "stl", box_stl ] ])
    version.version_files.destroy_all

    AnalyzeModelVersionMeshJob.perform_now(version.id)

    assert_equal "pending", version.reload.mesh_analysis_status
    assert_not_predicate version, :deliverable?
  end

  private

  def open_box_stl
    lines = box_stl.lines
    (lines[0...-8] + [ lines.last ]).join
  end

  def build_version(files, file_kind: "stl")
    version = @model.model_versions.create!(
      number: @model.model_versions.maximum(:number).to_i.clamp(1..) + 1,
      file_kind: file_kind, file_hash: "sha256:#{'b' * 64}", changelog: "Bundle.",
      changelog_hash: "sha256:#{'c' * 64}", published_at: Time.current
    )
    version.file.attach(io: StringIO.new(files.first[2]), filename: files.first[0],
                        content_type: "model/#{files.first[1]}")
    files.each_with_index do |(filename, kind, bytes), index|
      version_file = version.version_files.create!(
        position: index, kind: kind, file_hash: "sha256:#{Digest::SHA256.hexdigest(bytes)}"
      )
      version_file.file.attach(io: StringIO.new(bytes), filename: filename, content_type: "model/#{kind}")
    end
    version
  end
end
