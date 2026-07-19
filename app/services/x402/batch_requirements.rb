module X402
  class BatchRequirements
    IncompatiblePayees = Class.new(StandardError)
    Match = Struct.new(:requirement, :item_amounts, keyword_init: true)

    def initialize(offers:, resource_url:, sandbox: false)
      @offers = offers
      requirement_class = sandbox ? Sandbox::Requirements : Requirements
      @requirements = offers.map { |offer| requirement_class.new(offer: offer, resource_url: resource_url) }
      @sandbox = sandbox
      @accepts = build_accepts
    end

    def payment_required(error: "payment required")
      body = {
        x402Version: 2,
        error: error,
        resource: {
          url: @requirements.first.payment_required.dig(:resource, :url),
          description: "batch of #{@offers.length} machine-paid print licenses",
          mimeType: "application/json"
        },
        accepts: @accepts.map { |option| option.except(:item_amounts) },
        batch: { license_count: @offers.length }
      }
      if @sandbox
        body.merge!(sandbox: true, warning: Sandbox::Requirements::WARNING)
      end
      body
    end

    def match(accepted)
      return nil unless accepted.is_a?(Hash) && accepted["extra"].is_a?(Hash)

      candidate = @accepts.find do |option|
        (Requirements::MATCH_KEYS - %w[amount]).all? do |key|
          option[key.to_sym].to_s == accepted[key].to_s
        end && option.dig(:extra, :feePayer) == accepted.dig("extra", "feePayer") &&
          extra_matches?(option, accepted) && amount_acceptable?(option, accepted["amount"])
      end
      return nil unless candidate

      signed_amount = accepted["amount"].to_i
      quotes = candidate.fetch(:item_amounts)
      Match.new(
        requirement: candidate.except(:item_amounts).merge(amount: signed_amount.to_s),
        item_amounts: distribute(signed_amount, quotes)
      )
    end

    private

    def build_accepts
      item_options = @requirements.map(&:accepts)
      assets = item_options.map { |options| options.map { |option| option[:asset] } }.reduce(:&) || []
      options = assets.filter_map do |asset|
        parts = item_options.map { |choices| choices.find { |choice| choice[:asset] == asset } }
        next if parts.any?(&:nil?)

        signature = parts.map { |part| [ part[:scheme], part[:network], part[:asset], part[:payTo], part.dig(:extra, :feePayer) ] }.uniq
        raise IncompatiblePayees if signature.length != 1

        amounts = parts.map { |part| Integer(part[:amount]) }
        parts.first.deep_dup.merge(amount: amounts.sum.to_s, item_amounts: amounts)
      end
      raise IncompatiblePayees if options.empty?

      # Preserve the lead currency of the first offer.
      lead_asset = item_options.first.first[:asset]
      options.sort_by { |option| option[:asset] == lead_asset ? 0 : 1 }
    end

    def amount_acceptable?(option, amount)
      value = amount.to_s
      return false unless value.match?(/\A[1-9]\d*\z/)
      return value.to_i == option[:amount].to_i unless option[:asset] == Requirements::HBAR_ASSET

      value.to_i.between?(
        option[:amount].to_i * Requirements::HBAR_TOLERANCE_FLOOR,
        option[:amount].to_i * Requirements::HBAR_TOLERANCE_CEILING
      )
    end

    def extra_matches?(option, accepted)
      return true unless @sandbox

      option.dig(:extra, :sandbox) == accepted.dig("extra", "sandbox")
    end

    def distribute(total, quotes)
      quoted_total = quotes.sum
      allocated = quotes[0...-1].map { |quote| total * quote / quoted_total }
      allocated << total - allocated.sum
      allocated.map(&:to_s)
    end
  end
end
