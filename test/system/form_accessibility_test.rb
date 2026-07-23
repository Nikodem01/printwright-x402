require "application_system_test_case"

class FormAccessibilityTest < ApplicationSystemTestCase
  test "a failed account save moves focus to the first invalid field" do
    designer = designers(:two)
    visit "/login"
    fill_in "email", with: designer.email_address
    fill_in "password", with: "password"
    click_on "Login"
    Capybara.using_wait_time(10) { assert_current_path designer_root_path }

    visit designer_account_path
    # A server-only validation (http link is refused) so native HTML5 required
    # checks don't intercept the submit; the display name stays valid.
    fill_in "Public links (optional, up to 3 — one HTTPS URL per line)", with: "http://insecure.example/x"
    click_button "Save profile"

    # Server re-renders 422; the form-errors controller focuses the invalid field.
    assert_selector "textarea#designer_profile_links_text[aria-invalid='true']"
    focused_id = page.evaluate_script("document.activeElement && document.activeElement.id")
    assert_equal "designer_profile_links_text", focused_id
  end
end
