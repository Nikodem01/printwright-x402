require "application_system_test_case"
require "webmock/minitest"
require_relative "../test_helpers/mesh_test_helper"

class DesignerHomeTest < ApplicationSystemTestCase
  include MeshTestHelper

  test "populated home remains readable without horizontal overflow" do
    designer = designers(:two)
    designer.update!(hedera_account_id: "0.0.7007")
    designer.update!(payout_account_verified_at: Time.current)
    model = designer.models3d.create!(title: "Responsive studio organizer",
      slug: "responsive-studio-organizer", status: "published", mesh_analysis_status: "passed")
    model.license_offers.create!(kind: "personal", price_cents: 250)

    visit "/login"
    fill_in "email", with: designer.email_address
    fill_in "password", with: "password"
    click_on "Login"

    assert_current_path designer_root_path
    assert_selector ".designer-site-header"
    assert_no_selector ".catalog-search"
    assert_selector "h1", text: designer.display_name
    assert_text "Your shop is live"
    assert_text "Business snapshot"
    assert_selector ".flash", text: "You have been logged in", count: 1

    [ [ 1280, 900, "1280" ], [ 768, 900, "768" ], [ 390, 844, "390" ] ].each do |width, height, tag|
      page.driver.browser.manage.window.resize_to(width, height)
      overflow = page.evaluate_script(
        "document.documentElement.scrollWidth - document.documentElement.clientWidth"
      )
      assert_operator overflow, :<=, 1, "designer home overflows by #{overflow}px at #{width}px"
      if width > 780
        assert_selector ".dash-nav-desktop", visible: true
        assert_no_selector ".dash-menu", visible: true
      else
        assert_no_selector ".dash-nav-desktop", visible: true
        assert_selector ".dash-menu", visible: true
        assert_selector ".dash-menu:not([open])"
        assert_selector ".dash-menu summary strong", text: "Overview"

        heading_top = page.evaluate_script("document.querySelector('.home-heading h1').getBoundingClientRect().top")
        primary_bottom = page.evaluate_script(
          "document.querySelector('.home-heading .btn-primary').getBoundingClientRect().bottom"
        )
        assert_operator heading_top, :<, height,
          "designer home title begins below the initial #{height}px viewport"
        assert_operator primary_bottom, :<=, height,
          "designer home primary action ends below the initial #{height}px viewport"
      end
      page.save_screenshot(Rails.root.join("tmp/screenshots/designer-home-#{tag}.png").to_s)
    end

    visit designer_root_path
    assert_selector ".dash-menu:not([open])"
    page.execute_script("document.querySelector('.dash-menu summary').click()")
    assert_selector ".dash-menu[open] .dash-nav-mobile a", text: "Sales", visible: true
    assert_selector ".dash-menu[open] .dash-nav-mobile a", text: "Payouts", visible: true
    page.save_screenshot(Rails.root.join("tmp/screenshots/designer-menu-open-390.png").to_s)
    page.execute_script(
      "document.querySelector('.dash-menu[open] .dash-nav-mobile a[href=\"/designer/sales\"]').click()"
    )
    assert_current_path designer_sales_path
    assert_selector ".dash-menu:not([open]) summary strong", text: "Sales"
  end

  test "blocked states expose specific recovery actions at desktop and phone widths" do
    stub_request(:get, %r{api\.pwnedpasswords\.com/range/}).to_return(status: 200, body: "")
    email = "recovery-#{SecureRandom.hex(4)}@example.com"
    visit "/create-account"
    fill_in "Studio / display name", with: "Recovery Test Studio"
    fill_in "Email address", with: email
    fill_in "Password", with: "verdigris-kettle-9-monsoon"
    click_button "Create Account"

    assert_selector "h1", text: "Recovery Test Studio"
    designer = Designer.find_by!(email_address: email)
    model = designer.models3d.create!(
      title: "Blocked mesh model", slug: "blocked-mesh-#{SecureRandom.hex(4)}",
      mesh_analysis_status: "failed", mesh_analysis: { "errors" => [ "wall too thin" ] }
    )
    attach_stl(model, box_stl, filename: "blocked.stl")
    designer.update!(
      payout_pending_account_id: "0.0.8123", payout_challenge: "challenge",
      payout_challenge_digest: "digest", payout_challenge_expires_at: 10.minutes.from_now,
      payout_change_requested_at: Time.current
    )
    designer.profile_verifications.create!(
      status: "failed", profile_url: "https://github.com/recovery-test",
      host: "github.com", challenge_token: "proof", expires_at: 10.minutes.from_now,
      last_error: "proof token is not visible in the public profile"
    )
    visit designer_root_path

    assert_button "Send verification email"
    assert_link "Fix failed analysis", href: edit_designer_model_path(model, anchor: "files")
    assert_link "Sign wallet proof", href: designer_payouts_path(anchor: "payout-destination")
    assert_link "Retry proof", href: designer_identity_path

    [ [ 1280, 900, "1280" ], [ 390, 844, "390" ] ].each do |width, height, tag|
      page.driver.browser.manage.window.resize_to(width, height)
      page.execute_script("document.querySelector('#tasks-title').scrollIntoView({ block: 'start' }); window.scrollBy(0, -140)")
      overflow = page.evaluate_script(
        "document.documentElement.scrollWidth - document.documentElement.clientWidth"
      )
      assert_operator overflow, :<=, 1, "recovery tasks overflow by #{overflow}px at #{width}px"
      assert_selector ".home-task", minimum: 4, visible: true
      page.save_screenshot(Rails.root.join("tmp/screenshots/designer-recovery-#{tag}.png").to_s)
    end

    click_link "Fix failed analysis"
    assert_current_path edit_designer_model_path(model)
    assert_link "Run analysis again", href: retry_analysis_designer_model_path(model)
    assert_text "Fix or replace the listed printable file"
  end
end
