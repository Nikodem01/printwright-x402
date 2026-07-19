module Chat
  # Global provider-call budget. The per-IP controller limit handles bursts;
  # this daily counter bounds distributed abuse of the public Gemini key.
  module UsageBudget
    DEFAULT_DAILY_MESSAGES = 500

    module_function

    def consume?
      limit = daily_messages
      return false unless limit.positive?

      count = RateLimitStore.increment(
        "chat-provider:#{Date.current.iso8601}", 1,
        expires_in: 1.day
      )
      count.nil? || count <= limit
    end

    def daily_messages
      value = ENV.fetch("CHAT_DAILY_MESSAGE_LIMIT", DEFAULT_DAILY_MESSAGES.to_s)
      value.match?(/\A\d+\z/) ? value.to_i : 0
    end
  end
end
