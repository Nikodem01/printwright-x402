require "net/http"

module Hedera
  # Live HBAR/USD rate from the mirror node's exchange-rate endpoint,
  # memoized per process for TTL. `X402_DEMO_HBAR_PRICE_CENTS`, when set,
  # pins the rate (tests, offline dev, or emergency override) — unset it to
  # quote live. Serve-stale-on-error: a mirror hiccup keeps the last rate.
  class ExchangeRate
    TTL = 60.seconds

    class << self
      # cents per 1 HBAR, as a Rational (mirror gives cent/hbar equivalents).
      def cents_per_hbar
        if (pin = ENV["X402_DEMO_HBAR_PRICE_CENTS"].presence)
          return Rational(Integer(pin))
        end
        refresh if @fetched_at.nil? || @fetched_at < TTL.ago
        @rate
      end

      # tinybars equal to the given US cents at the current rate; nil if no
      # rate is available (callers drop the HBAR option rather than guess).
      def tinybars_for_cents(cents)
        rate = cents_per_hbar
        return nil if rate.nil? || rate.zero?
        (Rational(cents) / rate * 100_000_000).to_i
      end

      def reset!
        @rate = @fetched_at = nil
      end

      private

      def refresh
        response = Hedera::Network.get("/api/v1/network/exchangerate")
        raise Hedera::Network::Unavailable, "exchange rate fetch failed: #{response.code}" unless response.code.to_i == 200

        current = JSON.parse(response.body).fetch("current_rate")
        @rate = Rational(current.fetch("cent_equivalent"), current.fetch("hbar_equivalent"))
        @fetched_at = Time.current
      rescue Hedera::Network::Unavailable, JSON::ParserError, KeyError, ArgumentError
        @fetched_at = Time.current # back off for a TTL, keep serving @rate (may be nil)
        @rate
      end
    end
  end
end
