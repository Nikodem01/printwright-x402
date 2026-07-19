require "test_helper"
require_relative "../../test_helpers/mesh_test_helper"

class MeshAnalysis::AnalyzerTest < ActiveSupport::TestCase
  include MeshTestHelper

  test "accepts a manifold mesh and binds the result to its exact bytes" do
    model = designers(:one).models3d.create!(title: "Accepted mesh", slug: "accepted-mesh")
    file = attach_stl(model, box_stl)

    result = MeshAnalysis::Analyzer.call([ file ])

    assert_empty result.errors
    assert_match(/\Asha256:[0-9a-f]{64}\z/, result.digest)
    assert_match(/\Asha256:[0-9a-f]{64}\z/, result.geometry_hash)
    assert_equal 12, result.files.first.fetch("triangle_count")
    assert_equal 0, result.files.first.fetch("boundary_edges")
  end

  test "rejects an open mesh with a designer-readable reason" do
    model = designers(:one).models3d.create!(title: "Broken mesh", slug: "broken-mesh")
    lines = box_stl.lines
    broken = (lines[0...-8] + [ lines.last ]).join
    file = attach_stl(model, broken, filename: "broken.stl")

    result = MeshAnalysis::Analyzer.call([ file ])

    assert result.errors.any? { |error| error.match?(/broken\.stl: is open \(\d+ boundary edges\)/) }
  end

  test "rejects a manifold solid below the minimum wall thickness" do
    model = designers(:one).models3d.create!(title: "Thin mesh", slug: "thin-mesh")
    file = attach_stl(model, box_stl(height: 0.2), filename: "thin.stl")

    result = MeshAnalysis::Analyzer.call([ file ])

    assert_includes result.errors.join(" "), "estimated wall thickness is 0.2 mm; minimum is 0.4 mm"
  end

  test "geometry hash ignores translation triangle order and byte formatting" do
    first_model = designers(:one).models3d.create!(title: "First mesh", slug: "first-mesh")
    second_model = designers(:two).models3d.create!(title: "Second mesh", slug: "second-mesh")
    first = attach_stl(first_model, box_stl, filename: "first.stl")
    second = attach_stl(second_model, box_stl(offset: [ 15.0, -4.0, 2.0 ], reverse: true), filename: "second.stl")

    first_result = MeshAnalysis::Analyzer.call([ first ])
    second_result = MeshAnalysis::Analyzer.call([ second ])

    assert_not_equal first_result.digest, second_result.digest
    assert_equal first_result.geometry_hash, second_result.geometry_hash
  end
end
