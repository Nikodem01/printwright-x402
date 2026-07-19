require "test_helper"

class RenderModelJobTest < ActiveJob::TestCase
  setup do
    @model = designers(:one).models3d.create!(title: "Auto rendered", slug: "auto-rendered")
    source = @model.model_files.create!(kind: "stl", position: 0)
    source.file.attach(
      io: Rails.root.join("db/seed_assets/calibration-cube.stl").open,
      filename: "calibration-cube.stl", content_type: "model/stl"
    )
  end

  test "attaches four automatic render files and replaces them idempotently" do
    with_fake_openscad do
      RenderModelJob.perform_now(@model.id)
      RenderModelJob.perform_now(@model.id)
    end

    assert_equal 4, @model.reload.render_files.length
    assert_equal %w[back front left right], @model.render_files.map { |file| file.file.filename.to_s }
      .map { |name| name.delete_prefix(RenderModelJob::AUTO_PREFIX).delete_suffix(".png") }.sort
    assert @model.render_files.all? { |file| file.file.content_type == "image/png" }
  end

  test "can replace supplied renders when explicitly requested" do
    supplied = @model.model_files.create!(kind: "render", position: 1)
    supplied.file.attach(
      io: Rails.root.join("db/seed_assets/calibration-cube.png").open,
      filename: "designer.png", content_type: "image/png"
    )

    with_fake_openscad { RenderModelJob.perform_now(@model.id, true) }

    assert_equal 4, @model.reload.render_files.length
    assert @model.render_files.none? { |file| file.file.filename.to_s == "designer.png" }
  end

  private

  def with_fake_openscad
    previous = ENV["OPENSCAD_BIN"]
    ENV["OPENSCAD_BIN"] = Rails.root.join("test/fixtures/files/fake_openscad").to_s
    yield
  ensure
    ENV["OPENSCAD_BIN"] = previous
  end
end
