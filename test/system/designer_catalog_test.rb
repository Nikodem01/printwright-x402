require "application_system_test_case"

class DesignerCatalogTest < ApplicationSystemTestCase
  test "the catalog manager filters, searches, and stays readable at both widths" do
    designer = designers(:two)
    designer.models3d.create!(title: "Published Flexi Fox",
      slug: "pub-flexi-#{SecureRandom.hex(4)}", status: "published", file_hash: "sha256:#{'a' * 64}")
    designer.models3d.create!(title: "Draft Desk Tidy",
      slug: "draft-desk-#{SecureRandom.hex(4)}", status: "draft")

    visit "/login"
    fill_in "email", with: designer.email_address
    fill_in "password", with: "password"
    click_on "Login"
    Capybara.using_wait_time(10) { assert_current_path designer_root_path }

    page.driver.browser.manage.window.resize_to(1280, 900)
    visit designer_models_path

    assert_selector "h1", text: "Models"
    assert_selector ".catalog-row", count: 2
    assert_link "Add model"

    click_link "Draft 1"
    assert_selector ".catalog-row", count: 1
    assert_selector ".catalog-title", text: "Draft Desk Tidy"

    [ [ 1280, 900, "1280" ], [ 390, 844, "390" ] ].each do |width, height, tag|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        "width" => width, "height" => height, "deviceScaleFactor" => 1, "mobile" => false)
      page.execute_script("window.scrollTo(0, 0)")
      overflow = page.evaluate_script(
        "document.documentElement.scrollWidth - document.documentElement.clientWidth"
      )
      assert_operator overflow, :<=, 1, "Catalog overflows by #{overflow}px at #{width}px"
      page.save_screenshot(Rails.root.join("tmp/screenshots/designer-catalog-#{tag}.png").to_s)
    end
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
