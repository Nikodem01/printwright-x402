require "test_helper"
require_relative "../../test_helpers/mesh_test_helper"

class Models::ReadinessTest < ActiveSupport::TestCase
  include MeshTestHelper

  setup do
    @designer = designers(:one)
    @model = @designer.models3d.create!(
      title: "Readiness fixture", slug: "readiness-#{SecureRandom.hex(4)}"
    )
  end

  test "required checks explain an incomplete draft without making recommendations blockers" do
    @designer.update!(status: :unverified)
    readiness = Models::Readiness.new(@model, @designer)

    assert_equal %i[blocked complete blocked blocked blocked],
      readiness.required_items.map(&:status)
    assert_equal 1, readiness.required_complete_count
    assert_equal 5, readiness.required_count
    assert_not readiness.ready_to_review?
    assert_equal "Verify your email before publishing.", readiness.review_blocker_message
    assert readiness.recommended_items.all? { |item| !item.required? }
  end

  test "attached analyzed bundle and offer are ready even when payout is not configured" do
    attach_stl(@model, box_stl, filename: "ready.stl")
    @model.license_offers.create!(kind: "personal", price_cents: 250)
    @model.update!(mesh_analysis_status: "passed")

    readiness = Models::Readiness.new(@model.reload, @designer)

    assert readiness.ready_to_review?
    assert_nil readiness.review_blocker_message
    assert_equal :recommended, readiness.items.find { |item| item.key == :payout }.status
  end

  test "analysis states retain the secure review blocker messages" do
    attach_stl(@model, box_stl)
    @model.license_offers.create!(kind: "personal", price_cents: 250)

    readiness = Models::Readiness.new(@model.reload, @designer)
    assert_equal :working, readiness.items.find { |item| item.key == :analysis }.status
    assert_equal "Mesh analysis is running for this exact file bundle. Review again after it passes.",
      readiness.review_blocker_message

    @model.update!(mesh_analysis_status: "failed", mesh_analysis: { "errors" => [ "open edge" ] })
    readiness = Models::Readiness.new(@model.reload, @designer)
    assert_equal :blocked, readiness.items.find { |item| item.key == :analysis }.status
    assert_equal "Publish blocked: open edge", readiness.review_blocker_message
  end

  test "recommended storefront details report independently" do
    render = @model.model_files.create!(kind: "render", position: 0)
    render.file.attach(
      io: StringIO.new("png"), filename: "render.png", content_type: "image/png"
    )
    @model.update!(
      description: "Useful buyer-facing details.", tags: %w[useful fixture],
      printability: { "materials" => [ "PLA" ], "est_print_minutes" => 30 }
    )

    statuses = Models::Readiness.new(@model.reload, @designer).recommended_items
      .index_by(&:key).transform_values(&:status)

    assert_equal :complete, statuses.fetch(:description)
    assert_equal :complete, statuses.fetch(:render)
    assert_equal :complete, statuses.fetch(:discovery)
    assert_equal :complete, statuses.fetch(:guidance)
    assert_equal :recommended, statuses.fetch(:payout)
  end

  test "blank optional license product does not satisfy offer readiness" do
    attach_stl(@model, box_stl)
    @model.license_offers.build(kind: "commercial_unit")

    readiness = Models::Readiness.new(@model, @designer)

    assert_equal :blocked, readiness.items.find { |item| item.key == :offer }.status
    assert_equal "Add at least one license offer first.", readiness.review_blocker_message
  end
end
