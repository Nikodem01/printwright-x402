require "test_helper"
require_relative "../../test_helpers/mesh_test_helper"

class Designer::ModelsPublishTest < ActionDispatch::IntegrationTest
  include MeshTestHelper

  setup do
    @designer = designers(:one)
    @designer.account_verified!
    @model = @designer.models3d.create!(title: "Publishable", slug: "publishable-widget")
    @model.license_offers.create!(kind: "personal", price_cents: 250)
    sign_in_as @designer
  end

  def publish!
    post review_designer_model_path(@model), params: { model3d: { title: @model.title } }
    token = css_select("input[name='review_token']").sole["value"]
    post publish_designer_model_path(@model), params: { warranty: "1", review_token: token }
  end

  def analyze!
    AnalyzeModelMeshJob.perform_now(@model.id)
    assert_equal "passed", @model.reload.mesh_analysis_status
  end

  test "a listing goes live with a cover image already attached, not one queued behind it" do
    attach_stl(@model, box_stl)
    analyze!

    with_fake_openscad { publish! }

    assert_predicate @model.reload, :published?
    # The card has an image the moment the listing is discoverable.
    assert @model.render_files.any? { |file| file.file.attached? }
  end

  # Publishing is the point of no return for a buyer's first impression, so a
  # listing we cannot illustrate does not go live.
  test "a listing we cannot illustrate is held back rather than published blank" do
    attach_stl(@model, box_stl)
    analyze!

    previous = ENV["OPENSCAD_BIN"]
    ENV["OPENSCAD_BIN"] = "/nonexistent/openscad"
    publish!

    assert_predicate @model.reload, :draft?
    follow_redirect!
    assert_match(/preview image/i, response.body)
  ensure
    ENV["OPENSCAD_BIN"] = previous
  end

  test "a designer image publishes without invoking the renderer at all" do
    attach_stl(@model, box_stl)
    render = @model.model_files.create!(kind: "render", position: 1)
    render.file.attach(io: Rails.root.join("db/seed_assets/calibration-cube.png").open,
                       filename: "designer.png", content_type: "image/png")
    analyze!

    previous = ENV["OPENSCAD_BIN"]
    ENV["OPENSCAD_BIN"] = "/nonexistent/openscad"
    publish!

    assert_predicate @model.reload, :published?
    assert_equal [ "designer.png" ], @model.render_files.map { |file| file.file.filename.to_s }
  ensure
    ENV["OPENSCAD_BIN"] = previous
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
