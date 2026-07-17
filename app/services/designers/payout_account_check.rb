require "net/http"

module Designers
  # Can this account actually RECEIVE the payment a settle would send it?
  # Mirrors the facilitator's own payTo preflight exactly (direct USDC
  # association, unlimited auto-association, or a free auto slot) — passing
  # here but failing at settle would strand a real payment, so the semantics
  # must not drift from @x402/hedera's isPayToAssociated.
  class PayoutAccountCheck

    def self.call(account_id)
      return false if account_id.blank? || account_id !~ /\A0\.0\.\d+\z/

      return true if associated_with_usdc?(account_id)

      account = fetch_json("/api/v1/accounts/#{account_id}")
      return false if account.nil?

      max_auto = account["max_automatic_token_associations"].to_i
      return true if max_auto == -1
      return false if max_auto.zero?

      consumed = count_automatic_associations(account_id)
      !consumed.nil? && consumed < max_auto
    end

    def self.associated_with_usdc?(account_id)
      body = fetch_json("/api/v1/accounts/#{account_id}/tokens?token.id=#{Hedera::Network.usdc_asset}")
      body.present? && body["tokens"].to_a.any?
    end

    def self.count_automatic_associations(account_id)
      consumed = 0
      path = "/api/v1/accounts/#{account_id}/tokens"
      while path
        page = fetch_json(path)
        return nil if page.nil?
        consumed += page["tokens"].to_a.count { |t| t["automatic_association"] }
        path = page.dig("links", "next")
      end
      consumed
    end

    def self.fetch_json(path)
      base = Hedera::Network.mirror_base
      response = Net::HTTP.get_response(URI("#{base}#{path}"))
      response.code.to_i == 200 ? JSON.parse(response.body) : nil
    rescue StandardError
      nil # unreachable mirror = unverified, never an exception in the publish flow
    end
  end
end
