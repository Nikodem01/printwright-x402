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
    PreviewMeshes::Attacher.call(@model)
    @model.license_offers.create!(kind: "personal", price_cents: 100)
  end

  test "decimated preview loads through importmap and retains its render fallback" do
    visit model_page_path(@model.slug)

    assert_selector ".model-preview[data-preview-state='ready']", wait: 10
    assert_selector ".model-preview-stage canvas[role='img']"
    assert_selector ".model-preview-stage img[hidden]", visible: :all
    assert_text "drag to rotate"
  end
end
