require "test_helper"
require "webmock/minitest"

class HardeningTest < ActionDispatch::IntegrationTest
  setup do
    ENV["X402_FACILITATOR_URL"] = "https://facilitator.test"
    ENV["X402_PAY_TO"] = "0.0.9584959"
    ENV["X402_DEMO_HBAR_PRICE_CENTS"] = "250"
    FacilitatorClient.reset_cache!
    stub_request(:get, "https://facilitator.test/supported").to_return(
      body: { kinds: [ { scheme: "exact", network: "hedera:testnet", extra: { feePayer: "0.0.7162784" } } ] }.to_json,
      headers: { "content-type" => "application/json" }
    )
    @model = Model3d.create!(
      designer: designers(:one), title: "Hard", slug: "hard-#{SecureRandom.hex(4)}",
      status: "published", file_hash: "sha256:abc"
    )
    @model.license_offers.create!(kind: "personal", price_cents: 250)
  end

  teardown do
    RateLimitStore.backend = nil
    FacilitatorClient.reset_cache!
  end

  test "API over the limit gets a machine-readable 429 with Retry-After" do
    RateLimitStore.backend = ActiveSupport::Cache::MemoryStore.new
    ENV["X402_DEMO_HBAR_PRICE_CENTS"] = "250"

    31.times { get "/api/v1/models/#{@model.id}/download", headers: { accept: "application/json" } }
    assert_response :too_many_requests
    assert_equal "rate_limited", response.parsed_body["error"]
    assert_equal "60", response.headers["Retry-After"]
  end

  test "limits are per-controller: hammering downloads leaves search alone" do
    RateLimitStore.backend = ActiveSupport::Cache::MemoryStore.new
    31.times { get "/api/v1/models/#{@model.id}/download", headers: { accept: "application/json" } }
    assert_response :too_many_requests

    get "/api/v1/models", headers: { accept: "application/json" }
    assert_response :success
  end

  test "CSP header is nonce-based for scripts and pages still render" do
    get model_page_path(@model.slug)
    assert_response :success
    csp = response.headers["Content-Security-Policy"]
    assert_includes csp, "script-src 'self' 'nonce-"
    assert_includes csp, "default-src 'self'"
    assert_includes csp, "frame-ancestors 'none'"
    assert_includes csp, "wss://relay.walletconnect.com"
    assert_includes csp, "frame-src 'self' https://verify.walletconnect.com"
    # the importmap inline script carries the nonce (or checkout JS breaks)
    assert_match(/<script type="importmap"[^>]*nonce=/, response.body)
  end

  test "printable certificate's print button script is nonced, not inline-attr" do
    purchase = Purchase.create!(
      license_offer: @model.license_offers.first, status: "settled",
      replay_key: SecureRandom.hex(32)
    )
    license = License.allocate!(purchase)
    license.update!(cert_json: { "v" => 1 })

    get verify_certificate_path(license.verify_slug)
    assert_response :success
    assert_no_match(/onclick=/, response.body)
    assert_match(/<script[^>]*nonce=/, response.body)
  end
end

class FacilitatorBreakerTest < ActiveSupport::TestCase
  setup do
    require "webmock/minitest"
    ENV["X402_FACILITATOR_URL"] = "https://facilitator.test"
    FacilitatorClient.reset_cache!
  end

  teardown { FacilitatorClient.reset_cache! }

  test "three consecutive failures open the circuit; cooldown closes it again" do
    WebMock.stub_request(:get, "https://facilitator.test/supported").to_timeout

    3.times do
      assert_raises(FacilitatorClient::Unavailable) { FacilitatorClient.new.supported }
    end
    error = assert_raises(FacilitatorClient::Unavailable) { FacilitatorClient.new.supported }
    assert_includes error.message, "circuit_open"

    WebMock.stub_request(:get, "https://facilitator.test/supported")
      .to_return(body: { kinds: [] }.to_json, headers: { "content-type" => "application/json" })
    travel_to 31.seconds.from_now do
      assert_equal({ "kinds" => [] }, FacilitatorClient.new.supported)
      assert_nil FacilitatorClient.breaker_opened_at
    end
  end

  test "a success resets the failure count" do
    WebMock.stub_request(:get, "https://facilitator.test/supported").to_timeout
    2.times { assert_raises(FacilitatorClient::Unavailable) { FacilitatorClient.new.supported } }

    WebMock.stub_request(:get, "https://facilitator.test/supported")
      .to_return(body: "{}", headers: { "content-type" => "application/json" })
    FacilitatorClient.new.supported
    assert_equal 0, FacilitatorClient.breaker_failures
  end
end
