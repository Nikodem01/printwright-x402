require "test_helper"

class DiscoveryTest < ActionDispatch::IntegrationTest
  test "openapi.json is served, parses, and covers every public endpoint" do
    get "/openapi.json"
    assert_response :success
    spec = JSON.parse(response.body)
    assert_equal "3.1.0", spec["openapi"]
    assert spec.dig("info", "x-guidance").present?
    assert_equal [ "/batches", "/certificates/{cert_id}", "/files/{token}", "/licenses/{id}/can", "/models", "/models/{id}", "/models/{id}/download",
                   "/sandbox/files/{cert_id}", "/sandbox/topics/{topic_id}/messages/{sequence_number}",
                   "/sandbox/transactions/{transaction_id}", "/stats" ],
                 spec["paths"].keys.sort
    operation = spec.dig("paths", "/models/{id}/download", "get")
    assert_equal [ "x402" ], operation.dig("x-payment-info", "protocols").flat_map(&:keys)
    assert_equal "dynamic", operation.dig("x-payment-info", "price", "mode")
    responses = operation["responses"]
    assert responses.key?("402"), "402 response must be documented"
    assert responses.dig("402", "headers").key?("PAYMENT-REQUIRED")
    assert responses.dig("402", "headers").key?("WWW-Authenticate")
    assert responses.dig("402", "headers").key?("X-Printwright-Sandbox")
    assert responses.dig("200", "headers").key?("PAYMENT-RESPONSE")
    printability = spec.dig("components", "schemas", "Printability")
    assert_equal %w[bed_min_mm est_print_minutes materials supports], printability["properties"].keys.sort
    assert_equal "#/components/schemas/Printability",
      spec.dig("components", "schemas", "ModelSummary", "properties", "printability", "$ref")
    assert_equal "checkLicense", spec.dig("paths", "/licenses/{id}/can", "get", "operationId")
    assert_equal "1", spec.dig("components", "schemas", "LicensePermissions", "properties", "schema_version", "const")
    assert_equal "getOpenBooks", spec.dig("paths", "/stats", "get", "operationId")
    assert_equal "buyLicenseBatch", spec.dig("paths", "/batches", "post", "operationId")
    assert_equal 20, spec.dig("components", "schemas", "BatchRequest", "properties", "items", "maxItems")
    assert_equal %w[hedera:testnet hedera:mainnet],
      spec.dig("components", "schemas", "OpenBooksStats", "properties", "network", "enum")
  end

  test "llms.txt is served with the buy flow" do
    get "/llms.txt"
    assert_response :success
    assert_includes response.body, "x402"
    assert_includes response.body, "/openapi.json"
    assert_includes response.body, "PAYMENT-SIGNATURE"
    assert_includes response.body, "X-Sandbox: true"
    assert_includes response.body, "PWC-1"
    assert_includes response.body, "printwright-verify"
  end

  test "PWC-1 JSON Schema is public and keeps the frozen certificate contract" do
    get "/pwc-1.schema.json"
    assert_response :success
    schema = JSON.parse(response.body)
    assert_equal "PWC-1 Print License Certificate", schema["title"]
    assert_equal false, schema["additionalProperties"]
    assert_equal 1, schema.dig("properties", "v", "const")
    assert_equal %w[v cert_id model_id model_hash designer license_type unit_serial
                    buyer_hint payment_tx issued_at terms_hash], schema["required"]
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
