module Hedera
  # The single seam for network-dependent facts. HEDERA_NETWORK=mainnet flips
  # every asset id, mirror URL, and explorer link in the app; nothing else
  # hard-codes a network. Asset ids verified against docs.hedera.com
  # (mainnet native USDC 0.0.456858; testnet 0.0.429274 — both 6 decimals).
  class Network
    USDC_BY_NETWORK = { "mainnet" => "0.0.456858", "testnet" => "0.0.429274" }.freeze

    class << self
      def name
        ENV.fetch("HEDERA_NETWORK", "testnet")
      end

      def caip2
        "hedera:#{name}"
      end

      def usdc_asset
        USDC_BY_NETWORK.fetch(name)
      end

      def mirror_base
        ENV.fetch("MIRROR_NODE_URL", "https://#{name}.mirrornode.hedera.com")
      end

      def hashscan_base
        "https://hashscan.io/#{name}"
      end
    end
  end
end
