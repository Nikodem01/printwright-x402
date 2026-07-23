require "test_helper"

class DesignerShellTest < ActionDispatch::IntegrationTest
  setup do
    @designer = designers(:two)
    sign_in_as @designer
  end

  test "designer routes use creator chrome and grouped navigation without buyer or protocol clutter" do
    get designer_root_path

    assert_response :success
    assert_select "body.designer-workspace"
    assert_select ".designer-site-header .wordmark[href=?]", designer_root_path
    assert_select ".designer-site-header .tagline", text: "Create, publish, and earn."
    assert_select ".designer-header-actions[aria-label='Workspace shortcuts']"
    assert_select ".designer-header-actions a[href=?]", root_path, text: "View marketplace"
    assert_select ".designer-header-actions a[href=?]", designer_path(@designer), text: "View public profile"
    assert_select ".designer-header-actions .theme-toggle", text: "Dark mode"

    assert_select ".catalog-search", count: 0
    assert_select "[data-cart-link]", count: 0
    assert_select ".header-actions a", text: "My library", count: 0
    assert_select "[data-hedera-wallet]", count: 0
    assert_select ".site-footer:not(.designer-site-footer)", count: 0
    assert_select ".designer-site-footer", text: /designer workspace.*View marketplace.*View public profile.*Privacy/m
    assert_no_match(/Hedera Consensus Service topic|Payments via x402/, response.body)

    %w[Workspace Catalog Business Integrations Settings].each do |group|
      assert_select ".dash-nav-group-title", text: group, count: 2
    end
    assert_select ".dash-nav-group-title", text: "Trust & protection", count: 2
    assert_select ".dash-nav a[href=?]", new_designer_model_path, text: "Add model", count: 2
    assert_select ".dash-nav a[href=?]", designer_imports_path, text: "Import catalog", count: 2
    assert_select ".dash-nav a[href=?]", new_designer_takedown_packet_path, text: "Protection", count: 2
  end

  test "authenticated marketplace pages retain the buyer shell unchanged" do
    get root_path

    assert_response :success
    assert_select "body.marketplace"
    assert_select ".designer-site-header", count: 0
    assert_select ".catalog-search form.search-form"
    assert_select ".header-actions a[href=?]", cart_path, text: /Cart/
    assert_select ".header-actions a[href=?]", new_license_library_path, text: "My library"
    assert_select ".header-actions a[href=?]", designer_root_path, text: "Designer home"
    assert_match(/Hedera Consensus Service topic/, response.body)
    assert_match(/Payments via x402/, response.body)
  end

  test "designer payout pages keep the local wallet loader without a buyer wallet control" do
    previous = ENV["WALLETCONNECT_PROJECT_ID"]
    ENV["WALLETCONNECT_PROJECT_ID"] = "public-test-project"

    get designer_payouts_path

    assert_response :success
    assert_select "body.designer-workspace[data-controller='wallet-loader']"
    assert_select 'body[data-wallet-loader-module-url-value*="hedera_wallet"]'
    assert_select "[data-hedera-wallet]", count: 0
    assert_select "form[action=?]", designer_payout_destination_path
  ensure
    ENV["WALLETCONNECT_PROJECT_ID"] = previous
  end
end
