require "application_system_test_case"

class DesignerWebhooksTest < ApplicationSystemTestCase
  test "the webhook manager exposes status controls and health, readable at both widths" do
    designer = designers(:two)
    endpoint = designer.webhook_endpoints.create!(
      url: "https://hooks.example/studio-two",
      secret_ciphertext: Webhooks::SecretBox.encrypt("whsec_#{SecureRandom.hex(32)}")
    )
    WebhookDelivery.create!(
      webhook_endpoint: endpoint, license: nil, status: "delivered", delivered_at: 1.hour.ago,
      attempts: 1, event_type: "webhook.test", target_kind: "designer",
      event_id: "evt_test_#{SecureRandom.hex(8)}", event_key: "webhook.test:#{SecureRandom.hex(8)}",
      url: endpoint.url, secret_ciphertext: endpoint.secret_ciphertext,
      payload: { "data" => { "message" => "Test event." } }
    )

    visit "/login"
    fill_in "email", with: designer.email_address
    fill_in "password", with: "password"
    click_on "Login"
    Capybara.using_wait_time(10) { assert_current_path designer_root_path }

    page.driver.browser.manage.window.resize_to(1280, 900)
    visit designer_webhook_endpoints_path

    assert_selector "h1", text: "Webhooks"
    assert_button "Pause"
    assert_button "Send test"
    assert_button "Rotate secret"
    assert_text "Last delivered"

    [ [ 1280, 900, "1280" ], [ 390, 844, "390" ] ].each do |width, height, tag|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        "width" => width, "height" => height, "deviceScaleFactor" => 1, "mobile" => false)
      page.execute_script("window.scrollTo(0, 0)")
      overflow = page.evaluate_script(
        "document.documentElement.scrollWidth - document.documentElement.clientWidth"
      )
      assert_operator overflow, :<=, 1, "Webhooks overflows by #{overflow}px at #{width}px"
      page.save_screenshot(Rails.root.join("tmp/screenshots/designer-webhooks-#{tag}.png").to_s)
    end
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
