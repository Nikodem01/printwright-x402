require "test_helper"
require_relative "../../test_helpers/mesh_test_helper"

class Models::CoverImageTest < ActiveSupport::TestCase
  include MeshTestHelper

  setup do
    @model = designers(:one).models3d.create!(title: "Cover", slug: "cover-#{SecureRandom.hex(4)}")
  end

  test "a designer image is left exactly as it is" do
    render = @model.model_files.create!(kind: "render", position: 1)
    render.file.attach(io: Rails.root.join("db/seed_assets/calibration-cube.png").open,
                       filename: "designer.png", content_type: "image/png")

    assert Models::CoverImage.ensure!(@model)
    assert_equal [ "designer.png" ], @model.reload.render_files.map { |file| file.file.filename.to_s }
  end

  test "a printable bundle with no image gets one rendered before the listing goes live" do
    attach_stl(@model, box_stl)

    with_fake_openscad { assert Models::CoverImage.ensure!(@model) }

    assert_equal 1, @model.reload.render_files.count
    assert_predicate @model.render_files.sole.file, :attached?
    assert_equal "image/png", @model.render_files.sole.file.content_type
  end

  # We can only render from an STL, so a bundle without one has no automatic
  # fallback and the designer has to supply the image.
  test "a bundle we cannot render reports that it has no cover" do
    file = @model.model_files.create!(kind: "3mf", position: 0)
    file.file.attach(io: StringIO.new("PK\x03\x04"), filename: "part.3mf", content_type: "model/3mf")

    assert_not Models::CoverImage.ensure!(@model)
    assert_empty @model.reload.render_files
  end

  test "a renderer failure reports no cover rather than raising into the request" do
    attach_stl(@model, box_stl)

    with_printwright(openscad_bin: "/nonexistent/openscad") do
      assert_not Models::CoverImage.ensure!(@model)
      assert_empty @model.reload.render_files
    end
  end

  private

  def with_fake_openscad(&block)
    with_printwright(openscad_bin: Rails.root.join("test/fixtures/files/fake_openscad").to_s, &block)
  end
end
