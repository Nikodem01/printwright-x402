require "test_helper"
require "webmock/minitest"

# V16: HEDERA_NETWORK=mainnet must flip every network-dependent fact with no
# other code change — and nothing may spend anything to prove it.
class Hedera::NetworkTest < ActiveSupport::TestCase
  setup do
    @was = ENV["HEDERA_NETWORK"]
    ENV["X402_PAY_TO"] = "0.0.9584959"
  end

  teardown { ENV["HEDERA_NETWORK"] = @was }

  test "testnet is the default everywhere" do
    ENV.delete("HEDERA_NETWORK")
    assert_equal "hedera:testnet", Hedera::Network.caip2
    assert_equal "0.0.429274", Hedera::Network.usdc_asset
    assert_equal "https://testnet.mirrornode.hedera.com", Hedera::Network.mirror_base
    assert_equal "https://hashscan.io/testnet", Hedera::Network.hashscan_base
  end

  test "mainnet flips network, docs-verified USDC id, mirror, and explorer" do
    ENV["HEDERA_NETWORK"] = "mainnet"
    assert_equal "hedera:mainnet", Hedera::Network.caip2
    assert_equal "0.0.456858", Hedera::Network.usdc_asset # docs.hedera.com, native USDC
    assert_equal "https://mainnet.mirrornode.hedera.com", Hedera::Network.mirror_base
    assert_equal "https://hashscan.io/mainnet", Hedera::Network.hashscan_base
  end

  test "mirror requests use the shared bounded client and normalize transport failures" do
    stub_request(:get, "https://testnet.mirrornode.hedera.com/api/v1/network/nodes?limit=1")
      .to_return(status: 200, body: "{}")
    assert_equal "200", Hedera::Network.get("/api/v1/network/nodes?limit=1").code

    stub_request(:get, "https://testnet.mirrornode.hedera.com/api/v1/network/nodes?limit=1").to_timeout
    assert_raises(Hedera::Network::Unavailable) do
      Hedera::Network.get("/api/v1/network/nodes?limit=1")
    end
  end

  test "under mainnet config a 402 quotes mainnet requirements without spending" do
    ENV["HEDERA_NETWORK"] = "mainnet"
    ENV["X402_DEMO_HBAR_PRICE_CENTS"] = "250"
    FacilitatorClient.reset_cache!
    stub_request(:get, %r{/supported}).to_return(
      body: { kinds: [ { scheme: "exact", network: "hedera:mainnet", extra: { feePayer: "0.0.111" } } ] }.to_json,
      headers: { "content-type" => "application/json" }
    )

    model = Model3d.create!(designer: designers(:one), title: "M", slug: "mainnet-#{SecureRandom.hex(4)}")
    offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    accepts = X402::Requirements.new(offer: offer, resource_url: "https://x/dl").accepts

    assert(accepts.all? { |a| a[:network] == "hedera:mainnet" })
    assert_equal "0.0.456858", accepts.first[:asset]
    assert_equal "0.0.111", accepts.first.dig(:extra, :feePayer)
  ensure
    FacilitatorClient.reset_cache!
  end
end
