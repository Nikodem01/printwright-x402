require "application_system_test_case"

class CatalogSearchTest < ApplicationSystemTestCase
  setup do
    page.driver.browser.manage.window.resize_to(1280, 900)
    @model = Model3d.create!(
      designer: designers(:one), title: "Needle Threader", slug: "system-needle-threader",
      tags: %w[needle sewing], description: "A small support-free sewing aid.",
      printability: { "supports" => false, "materials" => %w[PLA] }, status: "published"
    )
    @model.license_offers.create!(kind: "personal", price_cents: 75)
    render = @model.model_files.create!(kind: "render", position: 0)
    render.file.attach(io: Rails.root.join("db/seed_assets/gear-toy.png").open,
                       filename: "needle-threader.png", content_type: "image/png")
  end

  test "browse, search, and filters land on the visible models section" do
    visit cart_path
    click_link "Browse models"
    assert_catalog_anchor_visible

    fill_in "Search the model catalog", with: "Needle Threader"
    click_button "Search"
    assert_selector ".model-card", text: "Needle Threader"
    assert_catalog_anchor_visible

    within ".filters" do
      click_link "Support-free"
    end
    assert_selector '.pill[aria-current="true"]', text: "Support-free"
    assert_catalog_anchor_visible
  end

  test "header search offers debounced server results and keyboard navigation" do
    visit root_path
    fill_in "Search the model catalog", with: "Needle"

    assert_selector ".search-suggestion", text: "Needle Threader"
    find("#catalog_search_input").send_keys(:arrow_down)
    assert page.evaluate_script("document.activeElement.classList.contains('search-suggestion')")

    find(".search-suggestion", text: "Needle Threader").click
    assert_current_path model_page_path(@model.slug)
    assert_selector "h1", text: "Needle Threader"
  end

  test "navigation remains visible above the page while scrolling" do
    visit root_path
    page.execute_script("window.scrollTo(0, document.body.scrollHeight)")

    header = find(".site-header")
    assert_equal "sticky", header.evaluate_script("getComputedStyle(this).position")
    assert_in_delta 0, header.rect.y - page.evaluate_script("window.scrollY"), 1
  end

  private

  def assert_catalog_anchor_visible
    assert_selector "#models"
    assert_includes page.current_url, "#models"
    top = page.evaluate_script("document.querySelector('#models').getBoundingClientRect().top")
    header_bottom = page.evaluate_script("document.querySelector('.site-header').getBoundingClientRect().bottom")
    viewport = page.evaluate_script("window.innerHeight")
    assert_operator top, :>=, header_bottom - 2
    assert_operator top, :<, viewport
  end
end
