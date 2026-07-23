require "application_system_test_case"

class DesignerProtectionTest < ApplicationSystemTestCase
  test "the protection center stays readable at both widths" do
    designer = designers(:two)
    model = designer.models3d.create!(title: "Guarded Flexi Dragon",
      slug: "guarded-flexi-#{SecureRandom.hex(4)}", status: "published",
      file_hash: "sha256:#{'a' * 64}", geometry_hash: "geom:#{'b' * 32}")
    offer = model.license_offers.create!(kind: "personal", price_cents: 350)
    purchase = Purchase.create!(license_offer: offer, status: "delivered",
      replay_key: SecureRandom.hex(32), asset: "0.0.429274", amount_base_units: "315000",
      payment_tx_id: "0.0.7162784@1.2")
    License.allocate!(purchase).update!(hcs_sequence_number: 12)

    visit "/login"
    fill_in "email", with: designer.email_address
    fill_in "password", with: "password"
    click_on "Login"
    Capybara.using_wait_time(10) { assert_current_path designer_root_path }

    page.driver.browser.manage.window.resize_to(1280, 900)
    visit designer_protection_path

    assert_selector "h1", text: "Protection"
    assert_selector "#protection-fingerprints-title"
    assert_selector "#protection-evidence-title"
    assert_text "Create takedown packet"

    [ [ 1280, 900, "1280" ], [ 390, 844, "390" ] ].each do |width, height, tag|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        "width" => width, "height" => height, "deviceScaleFactor" => 1, "mobile" => false)
      page.execute_script("window.scrollTo(0, 0)")
      overflow = page.evaluate_script(
        "document.documentElement.scrollWidth - document.documentElement.clientWidth"
      )
      assert_operator overflow, :<=, 1, "Protection overflows by #{overflow}px at #{width}px"
      page.save_screenshot(Rails.root.join("tmp/screenshots/designer-protection-#{tag}.png").to_s)
    end
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
