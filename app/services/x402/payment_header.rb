module X402
  # Reads the client's payment payload: v2 header first, v1 fallback.
  module PaymentHeader
    InvalidPayload = Class.new(StandardError)

    HEADER_NAMES = %w[PAYMENT-SIGNATURE X-PAYMENT].freeze

    def self.raw(request)
      HEADER_NAMES.filter_map { |name| request.headers[name] }.first
    end

    def self.decode(request)
      encoded = raw(request) or raise InvalidPayload, "missing payment header"
      raise InvalidPayload, "payment header is not a string" unless encoded.is_a?(String)

      payload = JSON.parse(Base64.strict_decode64(encoded))
      raise InvalidPayload, "payload is not an object" unless payload.is_a?(Hash)
      accepted = payload["accepted"]
      details = payload["payload"]
      transaction = details["transaction"] if details.is_a?(Hash)
      unless accepted.is_a?(Hash) && details.is_a?(Hash) && transaction.is_a?(String) && transaction.present?
        raise InvalidPayload, "payload missing accepted/transaction"
      end
      payload
    rescue ArgumentError, JSON::ParserError
      raise InvalidPayload, "payment header is not base64-encoded JSON"
    end
  end
end
