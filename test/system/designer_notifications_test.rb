require "application_system_test_case"

# Rendering, responsiveness, and privacy need the real browser; the
# mark-all-read round trip is deterministic form navigation and runs under
# rack below (DesignerNotificationsFlowTest), because headless Chrome in this
# environment intermittently drops a session's later form interactions
# outright (instrumented: no click/submit event, no request — the same
# non-repeating timing class Iteration 6 recorded for checkout/chat tests).
class DesignerNotificationsTest < ApplicationSystemTestCase
  test "the populated stream reads clean at both widths and never shows buyer identity" do
    designer = designers(:two)
    model = designer.models3d.create!(title: "Responsive notifier organizer",
      slug: "responsive-notifier-#{SecureRandom.hex(4)}", status: "published")
    offer = model.license_offers.create!(kind: "personal", price_cents: 250)

    # A real sale, delivered through the actual emission path (WebhookFanoutJob) —
    # proves the buyer_hint on the underlying purchase never reaches this page.
    purchase = Purchase.create!(license_offer: offer, status: "delivered", replay_key: SecureRandom.hex(32),
      buyer_hint: "private-buyer@example.com", asset: "0.0.429274", amount_base_units: "225000",
      payment_tx_id: "0.0.7162784@123.456")
    license = License.allocate!(purchase)
    WebhookFanoutJob.perform_now(license.id, "sale.completed")

    SellerNotification.record!(designer: designer, kind: "payout_completed",
      payload: { asset: "0.0.429274", amount_base_units: "225000", tx_id: "0.0.9067781@1.2" })
    SellerNotification.record!(designer: designer, kind: "payout_failed",
      payload: { asset: "0.0.429274", amount_base_units: "90000", error_code: "service_unavailable" })
    SellerNotification.record!(designer: designer, kind: "mesh_analysis_failed", model3d: model,
      payload: { errors: [ "wall too thin" ] })
    SellerNotification.record!(designer: designer, kind: "webhook_delivery_failed",
      payload: { url: "https://hooks.example/printwright", event_type: "sale.completed",
                 last_error: "callback returned HTTP 503" })
    SellerNotification.record!(designer: designer, kind: "identity_verification_failed",
      payload: { profile_url: "https://github.com/studio-two", host: "github.com",
                 reason: "proof token is not visible in the public profile" })

    visit "/login"
    fill_in "email", with: designer.email_address
    fill_in "password", with: "password"
    click_on "Login"
    Capybara.using_wait_time(10) { assert_current_path designer_root_path }

    # A prior test in this shared browser may leave a phone-sized window, and
    # the desktop-nav assertions need the desktop breakpoint. Safe here: this
    # test performs no clicks after the resize.
    page.driver.browser.manage.window.resize_to(1280, 900)
    visit designer_notifications_path

    assert_selector "h1", text: "Notifications"
    assert_selector ".dash-nav-desktop a", text: /Notifications\s*6/
    assert_selector ".badge", text: "Unread", minimum: 6
    assert_button "Mark all read"
    assert_no_text "private-buyer@example.com"

    # Viewport checks use CDP device-metrics emulation rather than a platform
    # window resize, which new-headless Chrome tracks unreliably.
    [ [ 1280, 900, "1280" ], [ 390, 844, "390" ] ].each do |width, height, tag|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        "width" => width, "height" => height, "deviceScaleFactor" => 1, "mobile" => false)
      page.execute_script("window.scrollTo(0, 0)")
      assert_no_page_overflow(width, "Notifications")
      page.save_screenshot(Rails.root.join("tmp/screenshots/designer-notifications-#{tag}.png").to_s)
    end
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  private

  def assert_no_page_overflow(width, page_name)
    overflow = page.evaluate_script(
      "document.documentElement.scrollWidth - document.documentElement.clientWidth"
    )
    assert_operator overflow, :<=, 1, "#{page_name} overflows by #{overflow}px at #{width}px"
  end
end

# The full user round trip — click, PATCH, 303, re-render — driven without a
# browser so it cannot be lost to driver timing. Turbo-submitted PATCH buttons
# in real Chrome are already exercised by the checkout/availability suites.
class DesignerNotificationsFlowTest < RackSystemTestCase
  test "marking all read clears unread state for this studio only" do
    designer = designers(:two)
    other = designers(:one)
    SellerNotification.record!(designer: designer, kind: "payout_completed",
      payload: { asset: "0.0.429274", amount_base_units: "225000", tx_id: "0.0.9067781@1.2" })
    SellerNotification.record!(designer: designer, kind: "mesh_analysis_passed", payload: {})
    other_row = SellerNotification.record!(designer: other, kind: "mesh_analysis_passed", payload: {})

    visit "/login"
    fill_in "email", with: designer.email_address
    fill_in "password", with: "password"
    click_on "Login"
    visit designer_notifications_path

    assert_selector ".badge", text: "Unread", count: 2
    click_button "Mark all read"

    assert_current_path designer_notifications_path
    assert_no_button "Mark all read"
    assert_no_selector ".badge", text: "Unread"
    assert_selector ".dash-nav-desktop a", text: "Notifications"
    assert_no_selector ".dash-nav-desktop a", text: /Notifications\s*\d/
    assert_nil other_row.reload.read_at
  end

  test "an empty stream is honest" do
    designer = designers(:one)

    visit "/login"
    fill_in "email", with: designer.email_address
    fill_in "password", with: "password"
    click_on "Login"
    visit designer_notifications_path

    assert_selector ".empty-state", text: /No notifications yet/
    assert_no_selector ".badge", text: "Unread"
  end
end
