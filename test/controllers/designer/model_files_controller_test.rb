require "test_helper"
require_relative "../../test_helpers/mesh_test_helper"

class Designer::ModelFilesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include MeshTestHelper

  setup do
    @designer = designers(:one)
    @model = @designer.models3d.create!(
      title: "Controller media", slug: "controller-media-#{SecureRandom.hex(4)}"
    )
    @printable = attach_stl(@model, box_stl)
    @render_one = attach_render("one.png")
    @render_two = attach_render("two.png")
    sign_in_as @designer
  end

  test "owner can feature, reorder, and remove current presentation media" do
    patch feature_designer_model_file_path(@model, @render_two)
    assert_redirected_to edit_designer_model_path(@model, anchor: "images")
    assert_equal @render_two.id, @model.reload.render_files.first.id

    patch move_designer_model_file_path(@model, @render_two), params: { direction: "down" }
    assert_redirected_to edit_designer_model_path(@model, anchor: "images")
    assert_equal @render_one.id, @model.reload.render_files.first.id

    delete designer_model_file_path(@model, @render_two)
    assert_redirected_to edit_designer_model_path(@model, anchor: "images")
    assert_not ModelFile.exists?(@render_two.id)
    assert ModelFile.exists?(@printable.id)
  end

  test "featured media becomes the first buyer-facing storefront image" do
    @model.update!(status: "published", file_hash: "sha256:#{'d' * 64}")
    @model.license_offers.create!(kind: "personal", price_cents: 250)

    patch feature_designer_model_file_path(@model, @render_two)
    get model_page_path(@model.slug)

    assert_response :success
    assert_select ".render-turntable-stage img", count: 1
    frame_urls = JSON.parse(css_select("[data-render-turntable-frames-value]").sole[
      "data-render-turntable-frames-value"
    ])
    assert_equal rails_storage_proxy_path(@render_two.file), frame_urls.first
  end

  test "another designer cannot manage any file" do
    sign_in_as designers(:two)

    delete designer_model_file_path(@model, @render_one)

    assert_response :not_found
    assert ModelFile.exists?(@render_one.id)
  end

  test "published buyer bundle and delivered license survive refused printable removal" do
    @model.update!(status: "published", file_hash: "sha256:#{'c' * 64}")
    offer = @model.license_offers.create!(kind: "personal", price_cents: 250)
    purchase = Purchase.create!(
      license_offer: offer, status: "delivered", amount_base_units: "2500000",
      asset: X402::Requirements.usdc_asset, replay_key: SecureRandom.hex(32)
    )
    license = License.allocate!(purchase)
    license.update!(cert_json: Certificates::Builder.call(license))
    original_certificate = license.cert_json.deep_dup

    assert_no_difference -> { ModelFile.count } do
      delete designer_model_file_path(@model, @printable)
    end

    assert_redirected_to edit_designer_model_path(@model, anchor: "files")
    follow_redirect!
    assert_select ".flash-bad", text: /certified printable bundle is frozen/i
    assert @printable.reload.file.attached?
    assert_equal "sha256:#{'c' * 64}", @model.reload.file_hash
    assert_equal original_certificate, license.reload.cert_json
    assert_equal @printable.id, license.purchase.license_offer.model3d.printable_files.sole.id
  end

  private

  def attach_render(filename)
    file = @model.model_files.create!(kind: "render", position: @model.model_files.count)
    file.file.attach(io: StringIO.new("png"), filename:, content_type: "image/png")
    file
  end
end
