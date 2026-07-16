module X402
  # Builds the PaymentRequired object for an offer (both assets, lead currency
  # first) and matches a client's `accepted` object against it.
  class Requirements
    NETWORK = "hedera:testnet".freeze
    HBAR_ASSET = "0.0.0".freeze
    USDC_ASSET = "0.0.429274".freeze
    USDC_BASE_UNITS_PER_CENT = 10_000 # 6 decimals: $0.01 = 10_000 units
    MAX_TIMEOUT_SECONDS = 180
    MATCH_KEYS = %w[scheme network amount asset payTo].freeze

    def initialize(offer:, resource_url:)
      @offer = offer
      @model = offer.model3d
      @resource_url = resource_url
    end

    def payment_required(error: "payment required")
      {
        x402Version: 2,
        error: error,
        resource: {
          url: @resource_url,
          description: description,
          mimeType: "application/json"
        },
        accepts: accepts
      }
    end

    def accepts
      options = [ usdc_option, hbar_option ]
      options.reverse! if @offer.currency == "HBAR"
      options
    end

    # The client must return one of our requirement objects verbatim;
    # anything else (tampered amount, wrong payTo, ...) is a mismatch.
    def match(accepted)
      return nil unless accepted.is_a?(Hash)
      accepts.find do |option|
        MATCH_KEYS.all? { |key| option[key.to_sym].to_s == accepted[key].to_s } &&
          option.dig(:extra, :feePayer) == accepted.dig("extra", "feePayer")
      end
    end

    private

    def description
      "#{@offer.kind} print license for '#{@model.title}' + file bundle"
    end

    def usdc_option
      base_option.merge(amount: (@offer.price_cents * USDC_BASE_UNITS_PER_CENT).to_s, asset: USDC_ASSET)
    end

    def hbar_option
      tinybars = (@offer.price_cents * 100_000_000) / demo_hbar_price_cents
      base_option.merge(amount: tinybars.to_s, asset: HBAR_ASSET)
    end

    def base_option
      {
        scheme: "exact",
        network: NETWORK,
        payTo: pay_to,
        maxTimeoutSeconds: MAX_TIMEOUT_SECONDS,
        extra: { feePayer: FacilitatorClient.fee_payer(NETWORK) }
      }
    end

    # Money goes straight to the designer when their account passed the
    # publish-time mirror check; otherwise treasury custody (owed balance
    # tracked in the ledger via held_by).
    def pay_to
      designer = @model.designer
      return designer.hedera_account_id if designer.payout_account_verified?
      ENV.fetch("X402_PAY_TO")
    end

    # Fixed demo conversion (cents per 1 HBAR); real quoting is out of scope.
    def demo_hbar_price_cents
      Integer(ENV.fetch("X402_DEMO_HBAR_PRICE_CENTS", "25"))
    end
  end
end
