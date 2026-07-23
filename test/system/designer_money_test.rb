require "application_system_test_case"

class DesignerMoneyTest < ApplicationSystemTestCase
  test "Sales, Payouts, and Analytics remain readable without page-level overflow" do
    ENV["X402_PAY_TO"] = "0.0.9584959"
    designer = designers(:two)
    designer.update!(hedera_account_id: "0.0.7007")
    designer.update!(payout_account_verified_at: Time.current,
      payout_account_control_verified_at: Time.current)
    model = designer.models3d.create!(title: "Responsive settlement organizer",
      slug: "responsive-settlement-#{SecureRandom.hex(4)}", status: "published")
    offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    purchase = Purchase.create!(license_offer: offer, status: "verified", buyer_hint: "private-buyer@example.com",
      asset: "0.0.429274", amount_base_units: "250000", payment_tx_id: "0.0.7162784@123.456",
      replay_key: SecureRandom.hex(32), requirements_json: { "payTo" => "0.0.9584959" })
    purchase.transition_to!(:settled)
    license = License.allocate!(purchase)
    purchase.transition_to!(:delivered)
    license.update!(hcs_sequence_number: 555)
    DownloadGrant.issue!(license).update!(uses: 1)
    PrintReport.create!(license: license)
    LedgerEntry.create!(purchase: purchase, designer: designer, entry_kind: "designer_payout",
      asset: "0.0.429274", amount_base_units: 225_000, held_by: "designer", tx_id: "0.0.9067781@789.012")
    failed_purchase = Purchase.create!(license_offer: offer, status: "verified",
      buyer_hint: "another-private-buyer@example.com", asset: "0.0.429274",
      amount_base_units: "250000", payment_tx_id: "0.0.7162784@124.457",
      replay_key: SecureRandom.hex(32), requirements_json: { "payTo" => "0.0.9584959" })
    failed_purchase.transition_to!(:settled)
    License.allocate!(failed_purchase)
    failed_purchase.transition_to!(:delivered)
    PayoutAttempt.create!(designer: designer, purchase: failed_purchase,
      ref: "purchase-#{failed_purchase.id}", asset: failed_purchase.asset,
      status: "failed", attempt_count: 10, last_error_code: "service_unavailable",
      last_attempted_at: 2.minutes.ago)
    3.times do
      ModelMetric.record!(model_ids: [ model.id ], event: "impression",
        channel: "human", source: "search", occurred_on: Date.current.iso8601)
    end
    ModelMetric.record!(model_ids: [ model.id ], event: "view",
      channel: "agent", source: "api", occurred_on: Date.current.iso8601)
    ModelMetric.record!(model_ids: [ model.id ], event: "payment_request",
      channel: "human", source: "checkout", occurred_on: Date.current.iso8601)

    visit "/login"
    fill_in "email", with: designer.email_address
    fill_in "password", with: "password"
    click_on "Login"

    [ [ 1280, 900, "1280" ], [ 390, 844, "390" ] ].each do |width, height, tag|
      page.driver.browser.manage.window.resize_to(width, height)

      visit designer_sales_path
      page.execute_script("window.scrollTo(0, 0)")
      assert_selector "h1", text: "Sales"
      assert_text "Responsive settlement organizer"
      assert_no_text "private-buyer@example.com"
      assert_no_page_overflow(width, "Sales")
      page.execute_script("window.scrollTo(0, 0)")
      page.save_screenshot(Rails.root.join("tmp/screenshots/designer-sales-#{tag}.png").to_s)

      visit designer_payouts_path
      page.execute_script("window.scrollTo(0, 0)")
      assert_selector "h1", text: "Payouts"
      assert_text "0.22 USDC"
      assert_text "Safe retry available"
      assert_button "Retry payout safely"
      assert_no_text "another-private-buyer@example.com"
      assert_no_page_overflow(width, "Payouts")
      page.execute_script("window.scrollTo(0, 0)")
      page.save_screenshot(Rails.root.join("tmp/screenshots/designer-payouts-#{tag}.png").to_s)

      visit designer_analytics_path
      page.execute_script("window.scrollTo(0, 0)")
      assert_selector "h1", text: "Analytics"
      assert_text "Responsive settlement organizer"
      assert_text "Listing impressions\n3"
      assert_text "x402 quote requests\n1"
      assert_selector ".analytics-fulfillment"
      assert_text "Settled on-chain\n2"
      assert_text "Certificates anchored\n1"
      assert_text "Files downloaded\n1"
      assert_text "Paid-holder print reports\n1"
      assert_no_text "private-buyer@example.com"
      assert_no_text "another-private-buyer@example.com"
      assert_no_page_overflow(width, "Analytics")
      page.execute_script("window.scrollTo(0, 0)")
      page.save_screenshot(Rails.root.join("tmp/screenshots/designer-analytics-#{tag}.png").to_s)
    end
  end

  private

  def assert_no_page_overflow(width, page_name)
    overflow = page.evaluate_script(
      "document.documentElement.scrollWidth - document.documentElement.clientWidth"
    )
    offenders = page.evaluate_script(<<~JS) if overflow > 1
      Array.from(document.querySelectorAll("body *"))
        .filter((element) => element.getBoundingClientRect().right > document.documentElement.clientWidth + 1)
        .slice(0, 8)
        .map((element) => `${element.tagName.toLowerCase()}.${element.className}: ` +
          `${Math.round(element.getBoundingClientRect().right)}px`)
        .join(", ")
    JS
    assert_operator overflow, :<=, 1,
      "#{page_name} overflows by #{overflow}px at #{width}px: #{offenders}"
  end
end
