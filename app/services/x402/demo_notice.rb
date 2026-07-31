module X402
  # An agent never renders the storefront banner, so the "this is a testnet
  # demo" fact has to travel over the wire in the shapes an agent already
  # parses: the 402 body it must read to pay, and a header on every API
  # response. Same claim through both doors — the agent-first invariant does
  # not permit humans to be told something machines are not.
  #
  # Mainnet is the seam: flipping HEDERA_NETWORK removes the notice from the
  # banner, the body and the header at once, so no surface can be left lying.
  module DemoNotice
    HEADER = "X-Printwright-Environment".freeze

    class << self
      def active?
        Hedera::Network.name != "mainnet"
      end

      # Merged into the 402 body under a `demo` key. x402 clients ignore
      # unknown fields, so this cannot break an agent that can already pay.
      def payload
        {
          network: Hedera::Network.name,
          funds: "test-only",
          message: "Demo deployment. Payments settle on Hedera #{Hedera::Network.name} " \
            "and carry no monetary value. Licenses and HCS certificates are genuinely " \
            "issued and verifiable, but are not a commercial grant of rights."
        }
      end

      def header_value
        "demo; network=#{Hedera::Network.name}; funds=test-only"
      end
    end
  end
end
