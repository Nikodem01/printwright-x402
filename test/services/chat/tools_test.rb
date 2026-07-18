require "test_helper"
require "webmock/minitest"

class Chat::ToolsTest < ActiveSupport::TestCase
  test "search_models trims each hit to what's useful and caps the result count" do
    models = Array.new(8) do |i|
      { "id" => i, "title" => "Model #{i}", "designer" => { "name" => "Demo" },
        "url" => "http://localhost:3000/api/v1/models/#{i}", "description" => "long unwanted text",
        "license_offers" => [ { "kind" => "personal", "price_cents" => 100, "currency" => "USDC" } ] }
    end
    stub_request(:get, "http://localhost:3000/api/v1/models?q=widget")
      .to_return(body: { models: models, count: 8 }.to_json, headers: { "content-type" => "application/json" })

    result = Chat::Tools.search_models("widget")
    assert_equal Chat::Tools::RESULT_LIMIT, result[:models].length
    hit = result[:models].first
    assert_equal %i[id title designer license_offers url], hit.keys
    assert_equal [ { kind: "personal", price: "$1.00", settles_in: "USDC" } ], hit[:license_offers]
  end

  test "price_cents (always US cents) is formatted as a dollar string, never handed over raw" do
    stub_request(:get, "http://localhost:3000/api/v1/models/5").to_return(
      body: { "id" => 5, "title" => "Snap Cable Clip", "slug" => "snap-cable-clip", "designer" => { "name" => "Demo" },
              "url" => "http://localhost:3000/api/v1/models/5",
              "license_offers" => [ { "kind" => "personal", "price_cents" => 90, "currency" => "USDC" } ] }.to_json,
      headers: { "content-type" => "application/json" }
    )

    offer = Chat::Tools.get_model("5")[:license_offers].first
    assert_equal "$0.90", offer[:price]
    assert_equal "USDC", offer[:settles_in]
  end

  test "the url points a human at the storefront page, not the raw JSON API endpoint" do
    stub_request(:get, "http://localhost:3000/api/v1/models/5").to_return(
      body: { "id" => 5, "title" => "Snap Cable Clip", "slug" => "snap-cable-clip", "designer" => { "name" => "Demo" },
              "url" => "http://localhost:3000/api/v1/models/5", "license_offers" => [] }.to_json,
      headers: { "content-type" => "application/json" }
    )

    assert_equal "http://localhost:3000/models/snap-cable-clip", Chat::Tools.get_model("5")[:url]
  end

  test "search_models with no matches returns an empty list, not an error" do
    stub_request(:get, "http://localhost:3000/api/v1/models?q=zzzznonsense")
      .to_return(body: { models: [], count: 0 }.to_json, headers: { "content-type" => "application/json" })

    assert_equal({ models: [], count: 0 }, Chat::Tools.search_models("zzzznonsense"))
  end

  test "get_model includes the description, not just the summary fields" do
    stub_request(:get, "http://localhost:3000/api/v1/models/5").to_return(
      body: { "id" => 5, "title" => "Cable Clip", "description" => "Tidy your cables.",
              "designer" => { "name" => "Demo" }, "url" => "http://localhost:3000/api/v1/models/5",
              "license_offers" => [] }.to_json,
      headers: { "content-type" => "application/json" }
    )

    result = Chat::Tools.get_model("5")
    assert_equal "Tidy your cables.", result[:description]
  end

  test "get_model returns a recoverable error for an unknown id" do
    stub_request(:get, "http://localhost:3000/api/v1/models/999")
      .to_return(status: 404, body: { error: "not_found" }.to_json, headers: { "content-type" => "application/json" })

    assert_equal "not_found", Chat::Tools.get_model("999")[:error]
  end

  test "a network failure degrades to a tool error instead of raising" do
    stub_request(:get, "http://localhost:3000/api/v1/models?q=x").to_timeout

    assert_equal "search_unavailable", Chat::Tools.search_models("x")[:error]
  end
end
