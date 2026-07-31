require "test_helper"
require "webmock/minitest"

# One fact — "this is a testnet demo, the money is not real" — has to reach two
# audiences that share no rendering path. A human reads a banner; an agent
# reads JSON and headers and never renders HTML at all. The agent-first
# invariant says neither door may be told less than the other, so both are
# asserted here together, in one file, so they cannot drift apart.
class DemoLabellingTest < ActionDispatch::IntegrationTest
  setup do
    set_printwright(hedera_network: "testnet")
    stub_x402_quoting
    @model = Model3d.create!(
      designer: designers(:one), title: "Demo Label Fixture", slug: "demo-label-fixture",
      file_hash: "sha256:#{Digest::SHA256.hexdigest('demo-label')}", status: "published"
    )
    @offer = @model.license_offers.create!(
      kind: "personal", price_cents: 250, currency: "USDC", terms_md: "T."
    )
  end

  teardown do
    restore_printwright
    FacilitatorClient.reset_cache!
    Hedera::ExchangeRate.reset!
  end

  # Building a 402 asks the facilitator who pays the network fee and the mirror
  # node for the HBAR rate. Neither is what this file tests, and both are stubbed
  # for testnet *and* mainnet so the off-switch case can build a real body too.
  def stub_x402_quoting
    FacilitatorClient.reset_cache!
    Hedera::ExchangeRate.reset!
    kinds = %w[testnet mainnet].map do |network|
      { x402Version: 2, scheme: "exact", network: "hedera:#{network}",
        extra: { feePayer: "0.0.7162784" } }
    end
    stub_request(:get, %r{/supported\z})
      .to_return(body: { kinds: kinds, extensions: [] }.to_json,
                 headers: { "content-type" => "application/json" })
    stub_request(:get, %r{/api/v1/network/exchangerate})
      .to_return(body: { current_rate: { cent_equivalent: 12, hbar_equivalent: 1 } }.to_json,
                 headers: { "content-type" => "application/json" })
  end

  def payment_required_body
    X402::Requirements
      .new(offer: @offer, resource_url: "https://printwright.test/api/v1/models/#{@model.slug}/download")
      .payment_required
  end

  # --- the human door ---

  test "storefront shows the demo banner above the fold" do
    get root_path

    assert_response :success
    assert_select "main .demo-banner", 1 do
      assert_select ".demo-badge", text: "Demo"
      assert_select ".demo-banner-copy", /no real money/i
    end
  end

  test "the banner is the first thing inside main, not buried under the catalog" do
    get root_path

    assert_select "main > *:first-child.demo-banner"
  end

  test "checkout and chat carry the same banner" do
    [ cart_path, chat_path ].each do |path|
      get path

      assert_response :success
      assert_select ".demo-banner", { count: 1 }, "#{path} is missing the demo banner"
    end
  end

  test "the testnet claim is made once per page, not duplicated into the trust strip" do
    get root_path

    assert_select ".trust-strip", text: /no monetary value/i, count: 0
  end

  test "sign-in renders through the application layout and keeps the banner" do
    get "/login"

    assert_response :success
    assert_select ".demo-banner", 1
  end

  # --- the agent door ---

  test "every API response carries the environment header" do
    get api_v1_models_path

    assert_response :success
    assert_equal "demo; network=testnet; funds=test-only",
      response.headers["X-Printwright-Environment"]
  end

  test "the header rides on error responses too, so a failing agent still learns the network" do
    get api_v1_model_path(id: "no-such-model")

    assert_response :not_found
    assert_equal "demo; network=testnet; funds=test-only",
      response.headers["X-Printwright-Environment"]
  end

  test "the 402 payment requirements body states the demo fact machine-readably" do
    body = payment_required_body

    assert_equal "testnet", body.dig(:demo, :network)
    assert_equal "test-only", body.dig(:demo, :funds)
    assert_match(/no monetary value/i, body.dig(:demo, :message))
  end

  # --- the off-switch ---

  test "mainnet silences the banner, the header and the 402 field together" do
    set_printwright(hedera_network: "mainnet")
    stub_x402_quoting # caches are keyed per network

    get root_path
    assert_select ".demo-banner", count: 0

    get api_v1_models_path
    assert_nil response.headers["X-Printwright-Environment"]

    assert_not payment_required_body.key?(:demo)
  end
end
