module Chat
  # Fail-closed configuration for the only chat operation that can lead to a
  # payment. Prices are US cents; settlement is restricted to exact USDC at
  # approval time so these integer caps are also the signed-amount caps.
  #
  # The values arrive already typed from config/initializers/printwright_config.rb,
  # where a malformed cap becomes 0 — buying off — rather than a guess.
  module PurchasePolicy
    PROPOSAL_LIFETIME = 10.minutes

    module_function

    def enabled?
      config.chat_purchases_enabled && max_spend_cents.positive? && daily_spend_cents.positive?
    end

    def max_spend_cents
      config.chat_max_spend_cents
    end

    def daily_spend_cents
      config.chat_daily_spend_cents
    end

    def config
      Rails.configuration.x.printwright
    end
    private_class_method :config
  end
end
