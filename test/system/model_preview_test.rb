require "application_system_test_case"

class ModelPreviewTest < ApplicationSystemTestCase
  setup do
    @model = Model3d.create!(
      designer: designers(:one), title: "Preview Gear", slug: "preview-gear",
      description: "Viewer regression fixture.", status: "published",
      file_hash: "sha256:#{Digest::SHA256.hexdigest('preview-gear')}"
    )
    source = @model.model_files.create!(kind: "stl", position: 0)
    source.file.attach(
      io: Rails.root.join("db/seed_assets/gear-toy.stl").open,
      filename: "gear-toy.stl", content_type: "model/stl"
    )
    render = @model.model_files.create!(kind: "render", position: 1)
    render.file.attach(
      io: Rails.root.join("db/seed_assets/gear-toy.png").open,
      filename: "gear-toy.png", content_type: "image/png"
    )
    3.times do |index|
      turn = @model.model_files.create!(kind: "render", position: index + 2)
      turn.file.attach(
        io: Rails.root.join("db/seed_assets/gear-toy.png").open,
        filename: "gear-toy-#{index + 2}.png", content_type: "image/png"
      )
    end
    PreviewMeshes::Attacher.call(@model)
    @model.license_offers.create!(kind: "personal", price_cents: 100)
  end

  test "rendered turntable changes frame on drag and zooms without exposing the mesh" do
    page.driver.browser.manage.window.resize_to(1280, 900)
    visit model_page_path(@model.slug)

    assert_selector ".model-preview[data-turntable-frame='0']", wait: 10
    assert_selector ".render-turntable-stage img"
    assert_text "drag to change view"
    assert_button "Add selection to cart"

    preview_top = find(".model-preview").rect.y
    checkout_top = find(".buy-panel").rect.y
    assert_in_delta preview_top, checkout_top, 2,
      "preview and checkout should begin on the same grid row"

    stage = find(".render-turntable-stage")
    dimensions = stage.rect
    assert_in_delta 4.0 / 3, dimensions.width.to_f / dimensions.height, 0.02

    # Drag farther than the complete frame set. JavaScript's `%` preserves a
    # negative sign, so one added frame count was not enough to wrap this case.
    page.driver.browser.action.move_to(stage.native).click_and_hold.move_by(120, 0).release.perform
    frame = find(".model-preview")["data-turntable-frame"].to_i
    assert_includes 0...4, frame
    assert_text(/Rendered view [1-4] of 4/)

    stage.execute_script("this.dispatchEvent(new WheelEvent('wheel', { deltaY: -100, bubbles: true, cancelable: true }))")
    transform = find(".render-turntable-stage img").evaluate_script("this.style.transform")
    assert_match(/scale\(1\.15/, transform)
  end
end
