require "application_system_test_case"

class DesignerIdentityTest < ApplicationSystemTestCase
  test "identity guidance, challenge, and history stay readable at both widths" do
    designer = designers(:two)
    designer.profile_verifications.create!(
      profile_url: "https://github.com/old-run", host: "github.com",
      challenge_token: "printwright-proof:old", expires_at: 2.days.from_now,
      status: "failed", last_error: "proof token is not visible in the public profile"
    )
    designer.profile_verifications.create!(
      profile_url: "https://github.com/studio-two", host: "github.com",
      challenge_token: "printwright-proof:current", expires_at: 2.days.from_now
    )

    visit "/login"
    fill_in "email", with: designer.email_address
    fill_in "password", with: "password"
    click_on "Login"
    Capybara.using_wait_time(10) { assert_current_path designer_root_path }

    page.driver.browser.manage.window.resize_to(1280, 900)
    visit designer_identity_path

    assert_selector "h1", text: "Verify a public profile"
    assert_text "GitHub, Printables, MakerWorld, Thingiverse, or Cults3D"
    assert_selector "[data-controller='clipboard'] button[aria-label='Copy proof token']"
    assert_selector "#identity-history-title", text: "Recent checks"

    [ [ 1280, 900, "1280" ], [ 390, 844, "390" ] ].each do |width, height, tag|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        "width" => width, "height" => height, "deviceScaleFactor" => 1, "mobile" => false)
      page.execute_script("window.scrollTo(0, 0)")
      overflow = page.evaluate_script(
        "document.documentElement.scrollWidth - document.documentElement.clientWidth"
      )
      assert_operator overflow, :<=, 1, "Identity overflows by #{overflow}px at #{width}px"
      page.save_screenshot(Rails.root.join("tmp/screenshots/designer-identity-#{tag}.png").to_s)
    end
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
