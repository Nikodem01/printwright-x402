require "test_helper"
require_relative "../../test_helpers/mesh_test_helper"

class Models::FileManagerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include MeshTestHelper

  setup do
    @model = designers(:one).models3d.create!(
      title: "Managed files", slug: "managed-files-#{SecureRandom.hex(4)}",
      mesh_analysis_status: "passed", mesh_analysis_digest: "sha256:old",
      geometry_hash: "sha256:geometry", mesh_analysis: { "watertight" => true }
    )
  end

  test "removing a draft printable invalidates analysis and queues the remaining bundle" do
    first = attach_stl(@model, box_stl, filename: "first.stl")
    second = attach_stl(@model, box_stl(width: 11), filename: "second.stl")

    assert_enqueued_with(job: AnalyzeModelMeshJob, args: [ @model.id ]) do
      Models::FileManager.destroy!(model: @model, file: first)
    end

    assert_not ModelFile.exists?(first.id)
    assert_equal [ second.id ], @model.reload.printable_files.map(&:id)
    assert_equal "pending", @model.mesh_analysis_status
    assert_nil @model.mesh_analysis_digest
    assert_nil @model.geometry_hash
    assert_equal({}, @model.mesh_analysis)
  end

  test "removing the last draft printable invalidates analysis without queuing empty work" do
    printable = attach_stl(@model, box_stl)

    assert_no_enqueued_jobs only: AnalyzeModelMeshJob do
      Models::FileManager.destroy!(model: @model, file: printable)
    end

    assert_empty @model.reload.printable_files
    assert_equal "pending", @model.mesh_analysis_status
    assert_nil @model.mesh_analysis_digest
  end

  test "published printable bundle cannot be removed or reordered" do
    first = attach_stl(@model, box_stl, filename: "first.stl")
    second = attach_stl(@model, box_stl(width: 11), filename: "second.stl")
    @model.update!(status: "published", file_hash: "sha256:#{'a' * 64}")

    error = assert_raises(Models::FileManager::Error) do
      Models::FileManager.destroy!(model: @model, file: first)
    end
    assert_match(/certified printable bundle is frozen/i, error.message)
    assert_raises(Models::FileManager::Error) do
      Models::FileManager.move!(model: @model, file: second, direction: "up")
    end

    assert_equal [ first.id, second.id ], @model.reload.printable_files.map(&:id)
    assert_equal "sha256:#{'a' * 64}", @model.file_hash
  end

  test "render media can be reordered and featured without changing certification" do
    printable = attach_stl(@model, box_stl)
    first = attach_render("first.png")
    second = attach_render("second.png")
    file_hash = "sha256:#{'b' * 64}"
    @model.update!(status: "published", file_hash: file_hash)

    Models::FileManager.feature!(model: @model, file: second)
    assert_equal [ second.id, first.id ], @model.reload.render_files.map(&:id)

    Models::FileManager.move!(model: @model, file: second, direction: "down")
    assert_equal [ first.id, second.id ], @model.reload.render_files.map(&:id)
    assert_equal [ printable.id ], @model.printable_files.map(&:id)
    assert_equal file_hash, @model.file_hash
    assert_equal "passed", @model.mesh_analysis_status
  end

  private

  def attach_render(filename)
    file = @model.model_files.create!(kind: "render", position: @model.model_files.count)
    file.file.attach(io: StringIO.new("png"), filename:, content_type: "image/png")
    file
  end
end
