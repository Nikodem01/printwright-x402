require "net/http"

# Thin HTTP client for the x402 facilitator (Blocky402 or self-hosted).
# Any transport failure or 5xx raises Unavailable — the caller must treat
# that as "outcome unknown", never as a payment failure (money may have moved).
class FacilitatorClient
  class Unavailable < StandardError; end

  TIMEOUT_SECONDS = 10

  # Circuit-breaker-lite: after BREAKER_THRESHOLD consecutive transport
  # failures, fail fast for BREAKER_COOLDOWN instead of stacking 10s timeouts
  # on every buyer. The caller semantics don't change — Unavailable either way.
  BREAKER_THRESHOLD = 3
  BREAKER_COOLDOWN = 30 # seconds

  class << self
    attr_accessor :breaker_failures, :breaker_opened_at

    def breaker_open?
      return false if breaker_opened_at.nil?
      if Time.current - breaker_opened_at >= BREAKER_COOLDOWN
        self.breaker_opened_at = nil # half-open: let the next request probe
        self.breaker_failures = 0
        false
      else
        true
      end
    end

    def breaker_fail!
      self.breaker_failures = breaker_failures.to_i + 1
      self.breaker_opened_at = Time.current if breaker_failures >= BREAKER_THRESHOLD
    end

    def breaker_ok!
      self.breaker_failures = 0
      self.breaker_opened_at = nil
    end
  end

  def self.fee_payer(network)
    @fee_payers ||= {}
    @fee_payers[network] ||= begin
      kind = new.supported.fetch("kinds", []).find { |k| k["network"] == network }
      kind&.dig("extra", "feePayer") or raise Unavailable, "facilitator does not support #{network}"
    end
  end

  def self.reset_cache!
    @fee_payers = nil
    breaker_ok!
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
    raise Unavailable, "circuit_open (retry in ≤#{BREAKER_COOLDOWN}s)" if self.class.breaker_open?

    begin
      response = Net::HTTP.start(
        @base.host, @base.port,
        use_ssl: @base.scheme == "https",
        open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS
      ) { |http| http.request(req) }

      raise Unavailable, "facilitator #{response.code}" if response.code.to_i >= 500
      parsed = JSON.parse(response.body)
      self.class.breaker_ok!
      parsed
    rescue Unavailable
      self.class.breaker_fail!
      raise
    rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET, SocketError, JSON::ParserError => e
      self.class.breaker_fail!
      raise Unavailable, e.message
    end
  end
end
