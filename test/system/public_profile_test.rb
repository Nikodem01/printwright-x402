require "application_system_test_case"

class PublicProfileTest < ApplicationSystemTestCase
  test "a populated designer profile stays readable at both widths" do
    designer = designers(:two)
    designer.update!(specialty: "Print-in-place mechanisms", location: "Adelaide, Australia",
      profile_links: [ "https://github.com/studio-two", "https://www.printables.com/@studio-two" ])
    featured = designer.models3d.create!(title: "Featured Flexi Fox",
      slug: "featured-flexi-fox-#{SecureRandom.hex(4)}", status: "published")
    featured.license_offers.create!(kind: "personal", price_cents: 350)
    other = designer.models3d.create!(title: "Everyday Cable Comb",
      slug: "everyday-cable-comb-#{SecureRandom.hex(4)}", status: "published")
    other.license_offers.create!(kind: "personal", price_cents: 150)
    designer.update!(featured_model_id: featured.id)

    page.driver.browser.manage.window.resize_to(1280, 900)
    visit designer_path(designer)

    assert_selector "h1", text: designer.display_name
    assert_text "Print-in-place mechanisms"
    assert_text "Adelaide, Australia"
    assert_selector "a[rel='nofollow noopener ugc']", count: 2
    assert_selector "h2", text: "Featured"

    [ [ 1280, 900, "1280" ], [ 390, 844, "390" ] ].each do |width, height, tag|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        "width" => width, "height" => height, "deviceScaleFactor" => 1, "mobile" => false)
      page.execute_script("window.scrollTo(0, 0)")
      overflow = page.evaluate_script(
        "document.documentElement.scrollWidth - document.documentElement.clientWidth"
      )
      assert_operator overflow, :<=, 1, "Profile overflows by #{overflow}px at #{width}px"
      page.save_screenshot(Rails.root.join("tmp/screenshots/public-profile-#{tag}.png").to_s)
    end
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
