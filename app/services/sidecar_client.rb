require "net/http"

# Client for the local HCS signing sidecar (the only key-holder).
class SidecarClient
  class Unavailable < StandardError; end
  class Rejected < StandardError; end

  TIMEOUT_SECONDS = 15

  def initialize(url: ENV.fetch("HEDERA_SIDECAR_URL", "http://localhost:4021"))
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

  # => { "transactionId" => ... } — a batched treasury -> designers transfer.
  # Money moves on 200; the CALLER records it (nothing here is retried).
  def payout(token_id:, transfers:, memo: nil)
    post("/payout", { tokenId: token_id, transfers: transfers, memo: memo }) do |body|
      raise Unavailable, body["error"] if body["error"] == "treasury_not_configured"
    end
  end

  # => { "tokenId" => ..., "transactionId" => ... }
  def create_collection(name:, symbol:, royalty_collector:, royalty_percent:)
    post("/create-collection", { name: name, symbol: symbol,
      royaltyCollector: royalty_collector, royaltyPercent: royalty_percent })
  end

  # => { "serial" => ..., "airdropTransactionId" => ..., "pending" => bool }
  def mint_airdrop(token_id:, metadata:, recipient:)
    post("/mint-airdrop", { tokenId: token_id, metadata: metadata, recipient: recipient })
  end

  private

  def post(path, payload)
    req = Net::HTTP::Post.new(path, "content-type" => "application/json")
    req["Authorization"] = "Bearer #{ENV.fetch('SIDECAR_TOKEN')}"
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
  rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET,
         SocketError, JSON::ParserError => e
    raise Unavailable, e.message
  end
end
