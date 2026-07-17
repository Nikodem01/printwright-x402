module X402
  # Builds the PaymentRequired object for an offer (both assets, lead currency
  # first) and matches a client's `accepted` object against it.
  class Requirements
    HBAR_ASSET = "0.0.0".freeze

    def self.network = Hedera::Network.caip2

    def self.usdc_asset = Hedera::Network.usdc_asset
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

    # HBAR quotes drift with the live rate; a payment signed against a quote
    # that moved before the retry landed must still verify. The floor bounds
    # the platform's worst case to 3% on HBAR offers; overpaying is always
    # accepted. USDC stays exact.
    HBAR_TOLERANCE_FLOOR = Rational(97, 100)

    def accepts
      options = [ usdc_option, hbar_option ].compact
      options.reverse! if @offer.currency == "HBAR"
      options
    end

    # The client must return one of our requirement objects — verbatim for
    # stable assets; HBAR amounts may drift within tolerance (the client's
    # amount becomes the requirement, since the signed tx must match it).
    def match(accepted)
      return nil unless accepted.is_a?(Hash)
      option = accepts.find do |candidate|
        (MATCH_KEYS - %w[amount]).all? { |key| candidate[key.to_sym].to_s == accepted[key].to_s } &&
          candidate.dig(:extra, :feePayer) == accepted.dig("extra", "feePayer") &&
          amount_acceptable?(candidate, accepted)
      end
      option && option.merge(amount: accepted["amount"].to_s)
    end

    private

    def description
      "#{@offer.kind} print license for '#{@model.title}' + file bundle"
    end

    def usdc_option
      base_option.merge(amount: (@offer.price_cents * USDC_BASE_UNITS_PER_CENT).to_s, asset: self.class.usdc_asset)
    end

    # Live-quoted; omitted entirely when no rate is available (never guess a
    # price). USDC remains, so the offer stays buyable.
    def hbar_option
      tinybars = Hedera::ExchangeRate.tinybars_for_cents(@offer.price_cents)
      tinybars && base_option.merge(amount: tinybars.to_s, asset: HBAR_ASSET)
    end

    def amount_acceptable?(option, accepted)
      ours = option[:amount].to_i
      theirs = accepted["amount"].to_s
      return false unless theirs.match?(/\A[1-9]\d*\z/)
      return theirs.to_i == ours unless option[:asset] == HBAR_ASSET
      theirs.to_i >= ours * HBAR_TOLERANCE_FLOOR
    end

    def base_option
      {
        scheme: "exact",
        network: self.class.network,
        payTo: pay_to,
        maxTimeoutSeconds: MAX_TIMEOUT_SECONDS,
        extra: { feePayer: FacilitatorClient.fee_payer(self.class.network) }
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
  end
end
