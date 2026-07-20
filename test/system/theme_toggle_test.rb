require "application_system_test_case"

class ThemeToggleTest < ApplicationSystemTestCase
  test "one click switches theme and the choice survives navigation" do
    visit root_path
    page.execute_script("localStorage.setItem('printwright-theme', 'light')")
    refresh

    assert_equal "light", page.evaluate_script("document.documentElement.dataset.theme")
    assert_button "Dark mode"
    assert_selector ".header-actions > .theme-toggle:last-child"

    click_button "Dark mode"

    assert_equal "dark", page.evaluate_script("document.documentElement.dataset.theme")
    assert_equal "dark", page.evaluate_script("localStorage.getItem('printwright-theme')")
    assert_button "Light mode"

    visit about_path

    assert_equal "dark", page.evaluate_script("document.documentElement.dataset.theme")
    assert_button "Light mode"
  ensure
    page.execute_script("localStorage.removeItem('printwright-theme')") if page.current_url.present?
  end
end
