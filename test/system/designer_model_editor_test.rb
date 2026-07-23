require "application_system_test_case"
require_relative "../test_helpers/mesh_test_helper"

class DesignerModelEditorTest < ApplicationSystemTestCase
  include MeshTestHelper

  setup do
    @designer = Designer.create!(
      email_address: "editor-#{SecureRandom.hex(4)}@example.com",
      password_digest: BCrypt::Password.create("password"),
      display_name: "Editor Test Studio", status: :verified
    )
    @model = @designer.models3d.create!(
      title: "Saved desk hook", slug: "saved-desk-hook-#{SecureRandom.hex(4)}",
      description: "A compact hook with two printable parts.", tags: %w[desk hook],
      category: "desk-organization", collections: %w[small-space],
      printability: { "materials" => [ "PLA" ], "est_print_minutes" => 42 },
      mesh_analysis_status: "passed"
    )
    attach_stl(@model, box_stl, filename: "hook-body.stl")
    @model.license_offers.create!(kind: "personal", price_cents: 250)
    render = @model.model_files.create!(kind: "render", position: 1)
    render.file.attach(
      io: Rails.root.join("db/seed_assets/calibration-cube.png").open,
      filename: "hook-render.png", content_type: "image/png"
    )

    visit "/login"
    fill_in "email", with: @designer.email_address
    fill_in "password", with: "password"
    click_on "Login"
    assert_current_path designer_root_path
    visit edit_designer_model_path(@model)
    assert_current_path edit_designer_model_path(@model)
  end

  test "editor shows readiness, local unsaved preview, and persists only on explicit save" do
    assert_selector ".listing-editor"
    assert_selector "#listing-readiness", text: "5 of 5 required"
    assert_text "Mesh analysis: passed"
    assert_text "hook-body.stl"
    assert_selector ".editor-media-card", text: "hook-render.png"
    assert_selector "[data-listing-editor-target='saveStatus']", text: "All changes saved"
    assert_equal "false", find(".listing-editor-form")["data-turbo"]
    assert_selector ".editor-license-card[data-license-state='active']", text: /Personal use.*2\.25 USDC/m
    assert_selector ".editor-license-card[data-license-state='available']", text: /Add Commercial per-unit license/
    assert_no_selector "select[name$='[kind]']"
    assert_field "Category", with: "desk-organization"
    assert_checked_field "Small-space wins"
    assert_selector "[data-listing-editor-target='previewCategory']", text: "Category: Desk organization"
    assert_selector "[data-listing-editor-target='previewCollections']", text: "Browse shelves: Small-space wins"
    assert_selector "[data-listing-editor-target='previewPrintability']", text: "Print facts: PLA · 42 min"

    set_with_input("Title", "Locally previewed desk hook")
    set_with_input("Description", "An updated local preview that is not public yet.")
    select "Workshop tools", from: "Category"
    uncheck "Small-space wins"
    check "Maker basics"
    click_button "jig"
    set_with_input("Materials", "PETG")
    check "This model needs supports"
    price_field = find_field("Price (USDC)", match: :first)
    assert_equal "model3d[license_offers_attributes][0][price_usdc]", price_field["name"]
    assert_equal "input->listing-editor#priceChanged", price_field["data-action"]
    price_field.execute_script("this.value = '3.75'")
    assert_equal "3.75", price_field.value
    price_field.execute_script("this.dispatchEvent(new Event('input', { bubbles: true }))")

    assert_selector "[data-listing-editor-target='saveStatus']", text: "Unsaved changes"
    assert_selector "[data-listing-editor-target='previewTitle']", text: "Locally previewed desk hook"
    assert_selector "[data-listing-editor-target='previewDescription']", text: /updated local preview/
    assert_selector "[data-listing-editor-target='previewCategory']", text: "Category: Workshop tools"
    assert_selector "[data-listing-editor-target='previewCollections']", text: "Browse shelves: Maker basics"
    assert_selector "[data-listing-editor-target='previewTags']", text: "Tags: desk, hook, jig"
    assert_selector "[data-listing-editor-target='previewPrintability']", text: "Print facts: PETG · supports needed · 42 min"
    assert_selector "[data-listing-editor-target='previewPrice']", text: "3.75 USDC"
    assert_selector "[data-license-net]", text: "3.38 USDC", match: :first
    assert_selector "[data-listing-editor-target='previewStatus']", text: /save to update the storefront/i
    assert_equal "Saved desk hook", @model.reload.title

    dismiss_confirm("Leave without saving your listing changes?") do
      click_link "View marketplace", match: :first
    end
    assert_current_path edit_designer_model_path(@model)
    assert_selector "[data-listing-editor-target='saveStatus']", text: "Unsaved changes"

    invalid_fields = page.evaluate_script(
      "Array.from(document.querySelectorAll('.listing-editor-form :invalid')).map((field) => field.name)"
    )
    assert_empty invalid_fields, "invalid editor fields: #{invalid_fields.join(', ')}"
    find(".listing-editor-form").execute_script("this.requestSubmit()")

    assert_selector ".flash-ok", text: "Updated."
    assert_current_path edit_designer_model_path(@model)
    assert_equal "Locally previewed desk hook", @model.reload.title
    assert_equal "workshop-tools", @model.category
    assert_equal %w[maker-basics], @model.collections
    assert_equal %w[desk hook jig], @model.tags
    assert_equal({ "supports" => true, "materials" => %w[PETG], "est_print_minutes" => 42 }, @model.printability)
    assert_equal 375, @model.license_offers.sole.price_cents
    assert_selector "[data-listing-editor-target='saveStatus']", text: "All changes saved"
  end

  test "discovery controls and preview remain usable at desktop and phone widths" do
    [ [ 1280, 900, "1280" ], [ 390, 844, "390" ] ].each do |width, height, tag|
      page.driver.browser.manage.window.resize_to(width, height)
      page.execute_script("document.querySelector('select[name=\"model3d[category]\"]').scrollIntoView({ block: 'center' })")

      assert_selector "select[name='model3d[category]']", visible: true
      assert_selector ".editor-taxonomy-options", visible: true
      assert_selector ".editor-tag-suggestions", text: /desk organizer/
      overflow = page.evaluate_script(
        "document.documentElement.scrollWidth - document.documentElement.clientWidth"
      )
      assert_operator overflow, :<=, 1, "discovery controls overflow by #{overflow}px at #{width}px"
      page.save_screenshot(Rails.root.join("tmp/screenshots/designer-discovery-#{tag}.png").to_s)
    end
  end

  test "editor remains usable without page overflow at desktop and phone widths" do
    [ [ 1280, 900, "1280" ], [ 390, 844, "390" ] ].each do |width, height, tag|
      page.driver.browser.manage.window.resize_to(width, height)
      overflow = page.evaluate_script(
        "document.documentElement.scrollWidth - document.documentElement.clientWidth"
      )
      assert_operator overflow, :<=, 1, "model editor overflows by #{overflow}px at #{width}px"

      if width == 390
        assert_selector ".editor-mobile-readiness", visible: true
        assert_selector ".listing-editor-aside", visible: true
      end
      page.save_screenshot(Rails.root.join("tmp/screenshots/designer-model-editor-#{tag}.png").to_s)
    end
  end

  test "license products remain readable and actionable at desktop and phone widths" do
    [ [ 1280, 900, "1280" ], [ 390, 844, "390" ] ].each do |width, height, tag|
      page.driver.browser.manage.window.resize_to(width, height)
      page.execute_script("document.querySelector('#license').scrollIntoView({ block: 'start' })")
      section_top = page.evaluate_script("document.querySelector('#license').getBoundingClientRect().top")
      assert_operator section_top, :<=, 170, "license section did not enter the viewport at #{width}px"

      assert_selector ".editor-license-card[data-license-state='active'][open]",
        text: /Personal use.*non-commercial.*2\.25 USDC/m
      assert_selector ".editor-license-card[data-license-state='available'] summary",
        text: /Add Commercial per-unit license/
      overflow = page.evaluate_script(
        "document.documentElement.scrollWidth - document.documentElement.clientWidth"
      )
      assert_operator overflow, :<=, 1, "license products overflow by #{overflow}px at #{width}px"
      page.save_screenshot(Rails.root.join("tmp/screenshots/designer-license-products-#{tag}.png").to_s)
    end

    commercial = find(".editor-license-card[data-license-state='available']")
    commercial.find("summary").click
    assert_selector ".editor-license-card[data-license-state='available'][open]"
    within(commercial) do
      assert_field "Price (USDC)"
      assert_text "one physical print for commercial sale"
      assert_text "Set a price and save to add this optional license."
    end
  end

  private

  def set_with_input(label, value)
    field = find_field(label)
    field.execute_script("this.value = #{value.to_json}; this.dispatchEvent(new Event('input', { bubbles: true }))")
  end
end
