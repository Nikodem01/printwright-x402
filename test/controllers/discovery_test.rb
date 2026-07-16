require "test_helper"

class DiscoveryTest < ActionDispatch::IntegrationTest
  test "openapi.json is served, parses, and covers the five public endpoints" do
    get "/openapi.json"
    assert_response :success
    spec = JSON.parse(response.body)
    assert_equal "3.1.0", spec["openapi"]
    assert_equal [ "/certificates/{cert_id}", "/files/{token}", "/models", "/models/{id}", "/models/{id}/download" ],
                 spec["paths"].keys.sort
    download = spec.dig("paths", "/models/{id}/download", "get", "responses")
    assert download.key?("402"), "402 response must be documented"
    assert download.dig("402", "headers").key?("PAYMENT-REQUIRED")
    assert download.dig("200", "headers").key?("PAYMENT-RESPONSE")
  end

  test "llms.txt is served with the buy flow" do
    get "/llms.txt"
    assert_response :success
    assert_includes response.body, "x402"
    assert_includes response.body, "/openapi.json"
    assert_includes response.body, "PAYMENT-SIGNATURE"
  end
end
