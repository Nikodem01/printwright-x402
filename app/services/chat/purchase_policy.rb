module Chat
  # Fail-closed configuration for the only chat operation that can lead to a
  # payment. Prices are US cents; settlement is restricted to exact USDC at
  # approval time so these integer caps are also the signed-amount caps.
  module PurchasePolicy
    PROPOSAL_LIFETIME = 10.minutes

    module_function

    def enabled?
      ENV["CHAT_PURCHASES_ENABLED"] == "true" && max_spend_cents.positive? && daily_spend_cents.positive?
    end

    def max_spend_cents
      cents("CHAT_MAX_SPEND_CENTS")
    end

    def daily_spend_cents
      value = ENV["CHAT_DAILY_SPEND_CENTS"]
      value.present? ? cents("CHAT_DAILY_SPEND_CENTS") : max_spend_cents
    end

    def cents(name)
      value = ENV[name].to_s
      value.match?(/\A\d+\z/) ? value.to_i : 0
    end
    private_class_method :cents
  end
end
