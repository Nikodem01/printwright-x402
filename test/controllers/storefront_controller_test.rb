require "test_helper"

class StorefrontControllerTest < ActionDispatch::IntegrationTest
  setup do
    @beaver = Model3d.create!(
      designer: designers(:one), title: "Articulated Beaver with Hat", slug: "beaver-with-hat",
      tags: %w[beaver hat], description: "A cheerful beaver.",
      printability: { "supports" => false, "materials" => %w[PLA], "est_print_minutes" => 95 },
      file_hash: "sha256:#{'a' * 64}", status: "published"
    )
    @beaver.license_offers.create!(kind: "personal", price_cents: 250, terms_md: "T.")
    Model3d.create!(designer: designers(:one), title: "Hidden Draft", slug: "hidden-draft", status: "draft")
  end

  test "browse lists published models with price and printability facts" do
    get root_path
    assert_response :success
    assert_select ".model-card", 1
    assert_select ".model-card h3", text: "Articulated Beaver with Hat"
    assert_select ".price", text: "$2.50"
    assert_select ".model-card", { text: /Hidden Draft/, count: 0 }
  end

  test "search narrows and empty search shows the empty state" do
    get root_path(q: "beaver")
    assert_select ".model-card", 1
    get root_path(q: "zeppelin")
    assert_select ".empty-state"
  end

  test "filter pills carry pressed state" do
    get root_path(supports_free: "1")
    assert_select '.pill[aria-pressed="true"]', text: "Support-free"
  end

  test "model page renders buy panel, trust strip, and JSON-LD product" do
    get model_page_path(@beaver.slug)
    assert_response :success
    assert_select "h1", text: @beaver.title
    assert_select ".buy-panel .offer-row", 1
    assert_select ".trust-strip .mono", text: /sha256:/
    assert_select 'script[type="application/ld+json"]' do |nodes|
      product = JSON.parse(nodes.first.text)
      assert_equal "Product", product["@type"]
      assert_equal "2.50", product["offers"].first["price"]
    end
  end

  test "draft model pages 404" do
    get model_page_path("hidden-draft")
    assert_response :not_found
  end
end
