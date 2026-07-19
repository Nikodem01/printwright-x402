require "test_helper"

class DiscoveryTest < ActionDispatch::IntegrationTest
  test "openapi.json is served, parses, and covers the five public endpoints" do
    get "/openapi.json"
    assert_response :success
    spec = JSON.parse(response.body)
    assert_equal "3.1.0", spec["openapi"]
    assert spec.dig("info", "x-guidance").present?
    assert_equal [ "/certificates/{cert_id}", "/files/{token}", "/models", "/models/{id}", "/models/{id}/download" ],
                 spec["paths"].keys.sort
    operation = spec.dig("paths", "/models/{id}/download", "get")
    assert_equal [ "x402" ], operation.dig("x-payment-info", "protocols").flat_map(&:keys)
    assert_equal "dynamic", operation.dig("x-payment-info", "price", "mode")
    responses = operation["responses"]
    assert responses.key?("402"), "402 response must be documented"
    assert responses.dig("402", "headers").key?("PAYMENT-REQUIRED")
    assert responses.dig("402", "headers").key?("WWW-Authenticate")
    assert responses.dig("200", "headers").key?("PAYMENT-RESPONSE")
  end

  test "llms.txt is served with the buy flow" do
    get "/llms.txt"
    assert_response :success
    assert_includes response.body, "x402"
    assert_includes response.body, "/openapi.json"
    assert_includes response.body, "PAYMENT-SIGNATURE"
  end

  # Staleness guard: derives the route list from Rails.application.routes
  # (never hardcoded) so a new /api/v1 endpoint without docs fails the suite.
  test "openapi.json documents every /api/v1 route the app actually has" do
    spec = JSON.parse(Rails.root.join("public/openapi.json").read)
    documented = spec["paths"].keys.map { |path| path.gsub(/\{[^}]+\}/, ":param") }

    actual_routes = Rails.application.routes.routes.filter_map do |route|
      controller = route.defaults[:controller].to_s
      next unless controller.start_with?("api/v1/")
      path = route.path.spec.to_s.sub("(.:format)", "").sub(%r{\A/api/v1}, "")
      path.gsub(/:\w+/, ":param")
    end.uniq

    missing = actual_routes - documented
    assert_empty missing, "public/openapi.json is missing route(s): #{missing.join(', ')}"
  end
end
