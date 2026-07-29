require "net/http"

# Client for the local HCS signing sidecar (the only key-holder).
class SidecarClient
  class Unavailable < StandardError; end
  class Ambiguous < StandardError; end
  class Rejected < StandardError; end

  TIMEOUT_SECONDS = 15

  def initialize(url: Rails.configuration.x.printwright.sidecar_url)
    @base = URI(url)
  end

  # => { "topicId" => ..., "sequenceNumber" => ..., "transactionId" => ... }
  def submit_cert(cert)
    post("/submit-cert", { cert: cert }) do |body|
      # A missing topic is a fixable configuration state (operator hasn't
      # restarted the sidecar after create-topic) — keep retrying. Real
      # rejections (e.g. cert_too_large) fail loudly: retrying can't fix them.
      raise Unavailable, body["error"] if body["error"] == "no_topic_configured"
    end
  end

  # => { "topicId" => ..., "sequenceNumber" => ..., "transactionId" => ... }
  def submit_version(version)
    post("/submit-version", { version: version }) do |body|
      raise Unavailable, body["error"] if body["error"] == "no_topic_configured"
    end
  end

  # => { "transactionId" => ... } — a batched treasury -> designers transfer.
  # Money moves on 200; the CALLER records it (nothing here is retried).
  def payout(token_id:, transfers:, memo: nil)
    post("/payout", { tokenId: token_id, transfers: transfers, memo: memo },
      ambiguous_on_response_loss: true) do |body|
      raise Unavailable, body["error"] if body["error"] == "treasury_not_configured"
      raise Ambiguous, body["error"] if body["error"] == "hedera_error"
    end
  end

  # Verifies a WalletConnect hedera_signMessage SignatureMap against the
  # current on-chain key for the claimed account. No private key enters Rails.
  def verify_payout_proof(account_id:, message:, signature_map:)
    post("/verify-payout-proof", {
      accountId: account_id, message: message, signatureMap: signature_map
    })
  end

  private

  def post(path, payload, ambiguous_on_response_loss: false)
    req = Net::HTTP::Post.new(path, "content-type" => "application/json")
    req["Authorization"] = "Bearer #{Rails.configuration.x.printwright.sidecar_token!}"
    req.body = JSON.generate(payload)

    response = Net::HTTP.start(
      @base.host, @base.port,
      use_ssl: @base.scheme == "https",
      open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS
    ) { |http| http.request(req) }

    body = JSON.parse(response.body)
    unless response.code.to_i == 200
      yield body if block_given?
      raise Rejected, body["error"]
    end
    body
  rescue Net::OpenTimeout, Errno::ECONNREFUSED, SocketError => e
    raise Unavailable, e.message
  rescue Net::ReadTimeout, Errno::ECONNRESET, JSON::ParserError => e
    error_class = ambiguous_on_response_loss ? Ambiguous : Unavailable
    raise error_class, e.message
  end
end
