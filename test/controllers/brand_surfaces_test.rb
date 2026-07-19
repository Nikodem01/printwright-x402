require "test_helper"

class BrandSurfacesTest < ActionDispatch::IntegrationTest
  test "storefront publishes complete social and application metadata" do
    get root_url

    assert_response :success
    assert_select 'meta[name="description"][content=?]',
      "License printable designs, pay per print, and verify every right on Hedera."
    assert_select 'meta[property="og:type"][content="website"]'
    assert_select 'meta[property="og:site_name"][content="Printwright"]'
    assert_select 'meta[property="og:title"][content="Printwright — every print, licensed"]'
    assert_select 'meta[property="og:image"][content$="/og-printwright.png"]'
    assert_select 'meta[property="og:image:width"][content="1200"]'
    assert_select 'meta[property="og:image:height"][content="630"]'
    assert_select 'meta[name="twitter:card"][content="summary_large_image"]'
    assert_select 'link[rel="manifest"][href="/manifest.json"]'
    assert_select 'link[rel="icon"][sizes="32x32"][href="/favicon-32.png"]'
    assert_select 'link[rel="apple-touch-icon"][sizes="180x180"][href="/apple-touch-icon.png"]'
    assert_select '.wordmark img[src="/brand-mark.svg"]'
  end

  test "manifest carries the public brand" do
    get "/manifest.json"

    assert_response :success
    manifest = response.parsed_body
    assert_equal "Printwright", manifest.fetch("name")
    assert_equal "Every print, licensed.", manifest.fetch("description")
    assert_equal "#0f766e", manifest.fetch("theme_color")
    assert_equal %w[192x192 512x512], manifest.fetch("icons").map { |icon| icon.fetch("sizes") }
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
