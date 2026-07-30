module Chat
  # Per-visitor messages stop one person consuming the shared allowance. The
  # provider counter is charged for every Gemini request, including tool-loop
  # follow-ups, so the configured global ceiling matches actual API usage.
  module UsageBudget
    DEFAULT_DAILY_VISITOR_MESSAGES = 25
    DEFAULT_DAILY_PROVIDER_CALLS = 500
    PROVIDER_LIMIT_MESSAGE = "The shopkeeper's shared daily assistant budget is reached. Please try again tomorrow."

    module_function

    def consume_visitor_message?(visitor)
      consume("chat-visitor:#{visitor}:#{Date.current.iso8601}", daily_visitor_messages)
    end

    def consume_provider_call?
      consume("chat-provider:#{Date.current.iso8601}", daily_provider_calls)
    end

    def daily_visitor_messages
      positive_integer(Rails.configuration.x.printwright.chat_daily_visitor_message_limit,
        DEFAULT_DAILY_VISITOR_MESSAGES)
    end

    def daily_provider_calls
      positive_integer(Rails.configuration.x.printwright.chat_daily_provider_call_limit,
        DEFAULT_DAILY_PROVIDER_CALLS)
    end

    def visitor_limit_message
      "You've reached the shopkeeper's #{daily_visitor_messages}-message daily fair-use limit. " \
        "Please try again tomorrow."
    end

    def consume(key, limit)
      return false unless limit.positive?

      count = RateLimitStore.increment(key, 1, expires_in: 1.day)
      count.nil? || count <= limit
    end
    private_class_method :consume

    def positive_integer(value, default)
      value = default if value.nil?
      value.to_s.match?(/\A\d+\z/) ? value.to_i : 0
    end
    private_class_method :positive_integer
  end
end
