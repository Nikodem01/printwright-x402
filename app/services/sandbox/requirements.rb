module Sandbox
  # A deliberately non-Hedera payment requirement used only when the caller
  # opts in with X-Sandbox: true. It preserves the x402 wire shape while every
  # identifier loudly says sandbox, so it cannot be mistaken for spendable or
  # on-chain value.
  class Requirements
    NETWORK = "hedera:sandbox".freeze
    ASSET = "sandbox:credit".freeze
    PAY_TO = "sandbox:designer".freeze
    FEE_PAYER = "sandbox:facilitator".freeze
    WARNING = "SIMULATION ONLY — NO HEDERA FUNDS MOVE".freeze
    MATCH_KEYS = %w[scheme network amount asset payTo].freeze

    def initialize(offer:, resource_url:)
      @offer = offer
      @resource_url = resource_url
    end

    def payment_required(error: "payment required")
      {
        x402Version: 2,
        error: error,
        sandbox: true,
        warning: WARNING,
        resource: {
          url: @resource_url,
          description: "SANDBOX #{@offer.kind} rehearsal — no printable model is delivered",
          mimeType: "application/json"
        },
        accepts: accepts
      }
    end

    def accepts
      [ option ]
    end

    def match(accepted)
      return nil unless accepted.is_a?(Hash)

      candidate = option
      same = MATCH_KEYS.all? { |key| candidate[key.to_sym].to_s == accepted[key].to_s } &&
        candidate.dig(:extra, :feePayer) == accepted.dig("extra", "feePayer") &&
        accepted.dig("extra", "sandbox") == true
      same ? candidate : nil
    end

    private

    def option
      {
        scheme: "exact",
        network: NETWORK,
        amount: @offer.price_cents.to_s,
        asset: ASSET,
        payTo: PAY_TO,
        maxTimeoutSeconds: 180,
        extra: {
          feePayer: FEE_PAYER,
          sandbox: true,
          warning: WARNING
        }
      }
    end
  end
end
