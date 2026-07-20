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
      positive_integer_env("CHAT_DAILY_VISITOR_MESSAGE_LIMIT", DEFAULT_DAILY_VISITOR_MESSAGES)
    end

    def daily_provider_calls
      value = ENV["CHAT_DAILY_PROVIDER_CALL_LIMIT"] || ENV["CHAT_DAILY_MESSAGE_LIMIT"]
      positive_integer(value, DEFAULT_DAILY_PROVIDER_CALLS)
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

    def positive_integer_env(name, default)
      positive_integer(ENV[name], default)
    end
    private_class_method :positive_integer_env

    def positive_integer(value, default)
      value = default.to_s if value.nil?
      value.match?(/\A\d+\z/) ? value.to_i : 0
    end
    private_class_method :positive_integer
  end
end
