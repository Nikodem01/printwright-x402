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
    req = Net::HTTP::Post.new("/submit-cert", "content-type" => "application/json")
    req["Authorization"] = "Bearer #{ENV.fetch('SIDECAR_TOKEN')}"
    req.body = JSON.generate(cert: cert)

    response = Net::HTTP.start(
      @base.host, @base.port,
      open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS
    ) { |http| http.request(req) }

    body = JSON.parse(response.body)
    raise Rejected, body["error"] unless response.code.to_i == 200
    body
  rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET,
         SocketError, JSON::ParserError => e
    raise Unavailable, e.message
  end
end
