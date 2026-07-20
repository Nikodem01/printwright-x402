require "test_helper"

class SearchSuggestionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @model = Model3d.create!(
      designer: designers(:one), title: "Needle Threader", slug: "needle-threader",
      tags: %w[needle sewing], description: "A small sewing aid.", status: "published"
    )
    @model.license_offers.create!(kind: "personal", price_cents: 75)
    render = @model.model_files.create!(kind: "render", position: 0)
    render.file.attach(io: Rails.root.join("db/seed_assets/gear-toy.png").open,
                       filename: "needle-threader.png", content_type: "image/png")
    Model3d.create!(designer: designers(:one), title: "Needle Draft", slug: "needle-draft", status: "draft")
  end

  test "returns compact published model suggestions with thumbnails and a full-results link" do
    get search_suggestions_path(q: "needle")

    assert_response :success
    assert_select "turbo-frame#catalog_search_suggestions"
    assert_select ".search-suggestion[href=?]", model_page_path(@model.slug), text: /Needle Threader/
    assert_select ".search-suggestion img", 1
    assert_select ".search-suggestion", text: /Needle Draft/, count: 0
    assert_select ".search-suggestion-all[href=?]", root_path(q: "needle", anchor: "models")
  end

  test "short queries do not scan the catalog" do
    get search_suggestions_path(q: "n")

    assert_response :success
    assert_select ".search-suggestion", count: 0
  end
end
