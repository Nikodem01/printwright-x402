require "test_helper"
require "webmock/minitest"

# V16: HEDERA_NETWORK=mainnet must flip every network-dependent fact with no
# other code change — and nothing may spend anything to prove it.
class Hedera::NetworkTest < ActiveSupport::TestCase
  test "testnet is the default everywhere" do
    assert_equal "testnet", Rails.configuration.x.printwright.hedera_network,
      "config/printwright.yml must default to testnet"
    assert_equal "hedera:testnet", Hedera::Network.caip2
    assert_equal "0.0.429274", Hedera::Network.usdc_asset
    assert_equal "https://testnet.mirrornode.hedera.com", Hedera::Network.mirror_base
    assert_equal "https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069",
      Hedera::Network.hcs_topic_url
    assert_equal "https://testnet.mirrornode.hedera.com/api/v1/transactions/0.0.7-1-2",
      Hedera::Network.transaction_url("0.0.7@1.2")
    assert_nil Hedera::Network.transaction_url("not-a-transaction")
  end

  test "mainnet flips network, docs-verified USDC id, and mirror links" do
    # mirror_node_url stays blank so the mirror has to follow the network —
    # the point of the switch is that one setting moves everything.
    with_printwright(hedera_network: "mainnet", mirror_node_url: nil) do
      assert_equal "hedera:mainnet", Hedera::Network.caip2
      assert_equal "0.0.456858", Hedera::Network.usdc_asset # docs.hedera.com, native USDC
      assert_equal "https://mainnet.mirrornode.hedera.com", Hedera::Network.mirror_base
      assert_equal "https://mainnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069",
        Hedera::Network.hcs_topic_url
    end
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
    set_printwright(hedera_network: "mainnet", demo_hbar_price_cents: "250")
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
