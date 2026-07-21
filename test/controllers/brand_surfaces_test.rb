require "test_helper"

class BrandSurfacesTest < ActionDispatch::IntegrationTest
  test "storefront publishes complete social and application metadata" do
    get root_url

    assert_response :success
    assert_select 'meta[name="description"][content=?]',
      "Licensed 3D-printable models an AI agent, print server, or person can buy over plain HTTP. Pay in HBAR or USDC on Hedera; every purchase mints a verifiable certificate."
    assert_select 'meta[property="og:type"][content="website"]'
    assert_select 'meta[property="og:site_name"][content="Printwright"]'
    assert_select 'meta[property="og:title"][content="Printwright — the 3D model store for AI agents"]'
    assert_select 'meta[property="og:image"][content$="/og-printwright.png"]'
    assert_select 'meta[property="og:image:width"][content="1200"]'
    assert_select 'meta[property="og:image:height"][content="630"]'
    assert_select 'meta[name="twitter:card"][content="summary_large_image"]'
    assert_select 'link[rel="manifest"][href="/manifest.json"]'
    assert_select 'link[rel="icon"][sizes="32x32"][href="/favicon-32.png"]'
    assert_select 'link[rel="apple-touch-icon"][sizes="180x180"][href="/apple-touch-icon.png"]'
    # The lockup is composed in ERB rather than shipped as a flattened SVG, so
    # the wordmark stays real type and the mark inherits currentColor — which
    # is what lets it take --chain in both themes.
    assert_select ".wordmark svg.brand-mark"
    assert_select ".wordmark .wordmark-name", text: "Printwright"
  end

  test "manifest carries the public brand" do
    get "/manifest.json"

    assert_response :success
    manifest = response.parsed_body
    assert_equal "Printwright", manifest.fetch("name")
    assert_equal "The 3D model store for agents.", manifest.fetch("description")
    assert_equal "#1B5E45", manifest.fetch("theme_color")
    assert_equal %w[192x192 512x512], manifest.fetch("icons").map { |icon| icon.fetch("sizes") }
  end

  test "header exposes buyer recovery and the correct designer account action" do
    get root_url

    assert_select "button[data-controller='theme'][data-action='theme#toggle']", text: "Dark mode"
    assert_select "button[data-theme-target='button'][aria-pressed='false']"
    assert_select ".header-actions > button.theme-toggle:last-child"
    assert_select ".header-actions a[href=?]", new_license_library_path, text: "My library"
    assert_select ".header-actions a[href=?]", "/login", text: "For designers"
    assert_select ".header-actions a[href=?]", designer_models_path, count: 0

    sign_in_as designers(:one)
    get root_url

    assert_select ".header-actions a[href=?]", designer_models_path, text: "Dashboard"
    assert_select ".header-actions a[href=?]", "/login", count: 0
  end

  test "layout restores a saved theme before application assets load" do
    get root_url

    bootstrap = css_select("head script").map(&:text).find { |script| script.include?("printwright-theme") }
    assert bootstrap
    assert_includes bootstrap, "document.documentElement.dataset.theme"
  end

  test "landing embeds one conversational purchase demo without a competing header action" do
    get root_url

    assert_select ".header-actions a[href=?]", chat_path, count: 0
    assert_select ".hero-shopkeeper form[action=?]", chat_path
    assert_select ".hero-shopkeeper a[href=?]", chat_path, text: /Open full chat/
    assert_select ".hero-shopkeeper .prompt-chip", minimum: 2
  end

  test "configured browser wallet is local, lazy, and names its Hedera network" do
    previous = ENV["WALLETCONNECT_PROJECT_ID"]
    ENV["WALLETCONNECT_PROJECT_ID"] = "public-test-project"

    get root_url

    assert_select 'body[data-controller="wallet-loader"]'
    assert_select 'body[data-wallet-loader-module-url-value*="hedera_wallet"]'
    assert_select '[data-hedera-wallet][data-network="testnet"]'
    assert_select "button[data-wallet-connect]", text: "Connect wallet"
    assert_no_match(/<script[^>]+src=[^>]+hedera_wallet/, response.body)
  ensure
    ENV["WALLETCONNECT_PROJECT_ID"] = previous
  end

  test "generated brand images retain their contract dimensions" do
    assert_equal [ 1200, 630 ], png_dimensions("public/og-printwright.png")
    assert_equal [ 512, 512 ], png_dimensions("public/icon.png")
    assert_equal [ 192, 192 ], png_dimensions("public/icon-192.png")
    assert_equal [ 180, 180 ], png_dimensions("public/apple-touch-icon.png")
    assert_equal [ 32, 32 ], png_dimensions("public/favicon-32.png")
  end

  private
    def png_dimensions(relative_path)
      File.binread(Rails.root.join(relative_path), 24).unpack("@16NN")
    end
end
