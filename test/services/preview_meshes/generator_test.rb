require "test_helper"

class PreviewMeshes::GeneratorTest < ActiveSupport::TestCase
  test "STL preview is deterministic, smaller, coarse, and deliberately open" do
    source = Rails.root.join("db/seed_assets/beaver-with-hat.stl").binread
    preview = PreviewMeshes::Generator.call(bytes: source, kind: "stl")

    assert_equal preview, PreviewMeshes::Generator.call(bytes: source, kind: "stl")
    assert preview.start_with?(PreviewMeshes::Generator::HEADER)
    assert_operator triangle_count(preview), :<, triangle_count(source)
    assert_operator preview.bytesize, :<, source.bytesize
    assert_operator open_edge_count(preview), :>, 0
  end

  test "3MF mesh becomes the same non-printable preview format" do
    preview = PreviewMeshes::Generator.call(bytes: simple_3mf, kind: "3mf")

    assert preview.start_with?(PreviewMeshes::Generator::HEADER)
    assert_equal 3, triangle_count(preview)
    assert_operator open_edge_count(preview), :>, 0
  end

  test "unsupported or malformed geometry has no interactive preview" do
    assert_nil PreviewMeshes::Generator.call(bytes: "not a mesh", kind: "stl")
    assert_nil PreviewMeshes::Generator.call(bytes: "not a zip", kind: "3mf")
  end

  private

  def triangle_count(bytes)
    bytes.byteslice(80, 4).unpack1("V")
  end

  def open_edge_count(bytes)
    edges = Hash.new(0)
    triangle_count(bytes).times do |index|
      vertices = bytes.byteslice(84 + (index * 50) + 12, 36).unpack("e9").each_slice(3).to_a
      [ [ 0, 1 ], [ 1, 2 ], [ 2, 0 ] ].each do |from, to|
        edge = [ vertices[from], vertices[to] ].map { |point| point.map { |value| (value * 100_000).round } }.sort
        edges[edge] += 1
      end
    end
    edges.count { |_edge, uses| uses != 2 }
  end

  def simple_3mf
    model = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
        <resources><object id="1" type="model"><mesh>
          <vertices>
            <vertex x="0" y="0" z="0"/><vertex x="10" y="0" z="0"/>
            <vertex x="0" y="10" z="0"/><vertex x="0" y="0" z="10"/>
          </vertices>
          <triangles>
            <triangle v1="0" v2="2" v3="1"/><triangle v1="0" v2="1" v3="3"/>
            <triangle v1="1" v2="2" v3="3"/><triangle v1="2" v2="0" v3="3"/>
          </triangles>
        </mesh></object></resources>
      </model>
    XML
    Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry("3D/3dmodel.model")
      zip.write(model)
    end.string
  end
end
