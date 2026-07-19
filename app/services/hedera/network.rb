require "net/http"

module Hedera
  # The single seam for network-dependent facts. HEDERA_NETWORK=mainnet flips
  # every asset id, mirror URL, and explorer link in the app; nothing else
  # hard-codes a network. Asset ids verified against docs.hedera.com
  # (mainnet native USDC 0.0.456858; testnet 0.0.429274 — both 6 decimals).
  class Network
    class Unavailable < StandardError; end

    OPEN_TIMEOUT_SECONDS = 2
    READ_TIMEOUT_SECONDS = 5
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

      def get(path)
        uri = path.is_a?(URI) ? path : URI("#{mirror_base}#{path}")
        request = Net::HTTP::Get.new(uri)
        Net::HTTP.start(
          uri.host, uri.port, use_ssl: uri.scheme == "https",
          open_timeout: OPEN_TIMEOUT_SECONDS, read_timeout: READ_TIMEOUT_SECONDS
        ) { |http| http.request(request) }
      rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET,
             SocketError, EOFError, Net::HTTPBadResponse, Net::ProtocolError => e
        raise Unavailable, e.message
      end
    end
  end
end
