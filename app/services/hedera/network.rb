require "net/http"

module Hedera
  # The single seam for network-dependent facts. HEDERA_NETWORK=mainnet flips
  # every asset id and Mirror Node URL in the app; nothing else
  # hard-codes a network. Asset ids verified against docs.hedera.com
  # (mainnet native USDC 0.0.456858; testnet 0.0.429274 — both 6 decimals).
  class Network
    class Unavailable < StandardError; end

    OPEN_TIMEOUT_SECONDS = 2
    READ_TIMEOUT_SECONDS = 5
    USDC_BY_NETWORK = { "mainnet" => "0.0.456858", "testnet" => "0.0.429274" }.freeze

    class << self
      def name
        config.hedera_network
      end

      def hcs_topic_id
        config.hcs_topic_id
      end

      def hcs_topic_url
        "#{mirror_base}/api/v1/topics/#{hcs_topic_id}"
      end

      def caip2
        "hedera:#{name}"
      end

      def usdc_asset
        USDC_BY_NETWORK.fetch(name)
      end

      # An explicit mirror URL wins; otherwise it follows the network, so
      # switching to mainnet cannot leave reads pointed at testnet.
      def mirror_base
        config.mirror_node_url.presence || "https://#{name}.mirrornode.hedera.com"
      end

      def transaction_url(transaction_id)
        return unless mirror_transaction_id(transaction_id)

        "https://hashscan.io/#{name}/transaction/#{transaction_id}"
      end

      def mirror_transaction_id(transaction_id)
        match = transaction_id.to_s.match(/\A(\d+\.\d+\.\d+)@(\d+)\.(\d{1,9})\z/)
        "#{match[1]}-#{match[2]}-#{match[3]}" if match
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

      private

      def config
        Rails.configuration.x.printwright
      end
    end
  end
end
