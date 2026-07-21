require "application_system_test_case"

# Capture-only: screenshots of the new auth surfaces at desktop + mobile widths
# for the visual gate. Run explicitly: bin/rails test:system TEST=test/system/auth_screens_test.rb
class AuthScreensTest < ApplicationSystemTestCase
  def shoot(name)
    [ [ 1280, 900, "1280" ], [ 390, 780, "390" ] ].each do |w, h, tag|
      page.driver.browser.manage.window.resize_to(w, h)
      page.save_screenshot(Rails.root.join("tmp/screenshots/auth-#{name}-#{tag}.png").to_s)
    end
  end

  test "capture signup, login, and account" do
    visit "/create-account"
    assert_selector "h1", text: "Create Account"
    shoot("signup")

    visit "/login"
    shoot("login")

    visit "/login"
    fill_in "email", with: designers(:two).email_address
    fill_in "password", with: "password"
    click_on "Login"
    visit "/designer/account"
    assert_selector "h1", text: "Account"
    shoot("account")
  end
end
