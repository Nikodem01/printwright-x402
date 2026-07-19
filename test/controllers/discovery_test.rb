require "test_helper"

class DiscoveryTest < ActionDispatch::IntegrationTest
  setup do
    @model = Model3d.create!(
      designer: designers(:one), title: "Crawler Cable Clip", slug: "crawler-cable-clip",
      description: "A small clip for routing one cable.", status: "published"
    )
    @model.license_offers.create!(
      kind: "personal", price_cents: 90, currency: "USDC", terms_version: "v1"
    )
    draft = Model3d.create!(
      designer: designers(:one), title: "Private Draft", slug: "private-draft", status: "draft"
    )
    draft.license_offers.create!(kind: "personal", price_cents: 10, terms_version: "v1")
  end

  test "well-known commerce manifest exposes each published x402 offer" do
    get "/.well-known/x402-catalog.json"

    assert_response :success
    assert_equal "application/json", response.media_type
    assert_match(/public/, response.headers["Cache-Control"])
    manifest = response.parsed_body
    assert_equal 1, manifest["schema_version"]
    assert_equal({ "version" => 2, "scheme" => "exact", "network" => X402::Requirements.network },
                 manifest["x402"])
    assert_equal [ "crawler-cable-clip" ], manifest["models"].pluck("slug")

    model = manifest["models"].sole
    offer = model["offers"].sole
    assert_equal [ "personal", 90, "USD", "USDC", true ],
                 [ offer["license_kind"], offer.dig("price", "cents"),
                   offer.dig("price", "currency"), offer["preferred_settlement_asset"], offer["available"] ]
    assert_nil offer["remaining_units"]
    assert_equal %w[0.0.429274 0.0.0], offer["settlement_assets"]
    assert_equal "v1", offer.dig("terms", "version")
    assert_includes offer.dig("terms", "permissions_url"), ".json"
    refute_includes response.body, "private-draft"
  end

  test "toy crawler follows manifest links and reaches an x402 challenge" do
    get "/.well-known/x402-catalog.json"
    model = response.parsed_body.fetch("models").sole
    offer = model.fetch("offers").sole

    [ model.fetch("page_url"), model.fetch("api_url"), offer.dig("terms", "permissions_url") ].each do |url|
      get URI(url).request_uri
      assert_response :success, url
    end

    get URI(offer.fetch("payment_url")).request_uri, headers: { "X-Sandbox" => "true" }
    assert_response :payment_required
    assert_equal 2, response.parsed_body["x402Version"]
    assert_equal "x402", response.headers["WWW-Authenticate"]
  end

  test "openapi.json is served, parses, and covers every public endpoint" do
    get "/openapi.json"
    assert_response :success
    spec = JSON.parse(response.body)
    assert_equal "3.1.0", spec["openapi"]
    assert spec.dig("info", "x-guidance").present?
    assert_equal [ "/batches", "/certificates/{cert_id}", "/files/{token}", "/licenses/{cert_id}/latest-version", "/licenses/{cert_id}/latest-version/file", "/licenses/{cert_id}/print_reports", "/licenses/{id}/can", "/models", "/models/{id}", "/models/{id}/download",
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
    assert_equal "reportSuccessfulPrint",
      spec.dig("paths", "/licenses/{cert_id}/print_reports", "post", "operationId")
    assert_equal "getLatestModelVersion",
      spec.dig("paths", "/licenses/{cert_id}/latest-version", "get", "operationId")
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
    assert_includes response.body, "/licenses/{cert_id}/print_reports"
    assert_includes response.body, "/licenses/{cert_id}/latest-version"
    assert_includes response.body, "get_latest_version"
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

  test "external-profile schema and live example preserve source licenses and file hashes" do
    get "/external-profile-v1.schema.json"
    assert_response :success
    schema = response.parsed_body
    required = schema.dig("properties", "models", "items", "required")
    assert_includes required, "source_url"
    assert_includes required, "source_license"
    assert_includes required, "files"

    get "/examples/external-profile-v1.json"
    assert_response :success
    example = response.parsed_body
    assert_equal [ "all-rights-reserved", "cc-by-nc-4.0" ], example.fetch("models").pluck("source_license")
    assert(example.fetch("models").all? do |model|
      model.fetch("files").all? { |file| file.fetch("sha256").match?(/\Asha256:[0-9a-f]{64}\z/) }
    end)
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
