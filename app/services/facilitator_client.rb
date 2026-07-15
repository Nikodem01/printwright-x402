require "net/http"

# Thin HTTP client for the x402 facilitator (Blocky402 or self-hosted).
# Any transport failure or 5xx raises Unavailable — the caller must treat
# that as "outcome unknown", never as a payment failure (money may have moved).
class FacilitatorClient
  class Unavailable < StandardError; end

  TIMEOUT_SECONDS = 10

  def self.fee_payer(network)
    @fee_payers ||= {}
    @fee_payers[network] ||= begin
      kind = new.supported.fetch("kinds", []).find { |k| k["network"] == network }
      kind&.dig("extra", "feePayer") or raise Unavailable, "facilitator does not support #{network}"
    end
  end

  def self.reset_cache!
    @fee_payers = nil
  end

  def initialize(url: ENV.fetch("X402_FACILITATOR_URL", "https://api.testnet.blocky402.com"))
    @base = URI(url)
  end

  def supported
    request(Net::HTTP::Get.new(path("/supported")))
  end

  # => { "isValid" => bool, "payer" => "0.0.x", "invalidReason" => ... }
  def verify(payment_payload, payment_requirements)
    post("/verify", payment_payload, payment_requirements)
  end

  # => { "success" => bool, "transaction" | "transactionId" => ..., "payer" => ..., "errorReason" => ... }
  def settle(payment_payload, payment_requirements)
    post("/settle", payment_payload, payment_requirements)
  end

  private

  def post(endpoint, payment_payload, payment_requirements)
    req = Net::HTTP::Post.new(path(endpoint), "content-type" => "application/json")
    req.body = JSON.generate(
      x402Version: 2,
      paymentPayload: payment_payload,
      paymentRequirements: payment_requirements
    )
    request(req)
  end

  def path(endpoint)
    "#{@base.path.chomp('/')}#{endpoint}"
  end

  def request(req)
    response = Net::HTTP.start(
      @base.host, @base.port,
      use_ssl: @base.scheme == "https",
      open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS
    ) { |http| http.request(req) }

    raise Unavailable, "facilitator #{response.code}" if response.code.to_i >= 500
    JSON.parse(response.body)
  rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET, SocketError, JSON::ParserError => e
    raise Unavailable, e.message
  end
end
