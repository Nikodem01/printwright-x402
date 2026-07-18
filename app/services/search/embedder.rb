require "net/http"

module Search
  # Text -> 768-float embedding via Gemini (gemini-embedding-001), the seam
  # that powers Model3d.semantic_search. Embeddings are a nice-to-have, not a
  # dependency: with no API key, or on any network hiccup, this degrades to
  # "unavailable" rather than raising — callers fall back to keyword/trigram
  # search instead of 500ing a user's request.
  class Embedder
    ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-001:embedContent".freeze
    DIMENSIONS = 768
    TIMEOUT_SECONDS = 3

    def initialize(api_key: ENV["GOOGLE_GENERATIVE_AI_API_KEY"])
      @api_key = api_key
    end

    def available?
      @api_key.present?
    end

    # => an Array of DIMENSIONS floats, or nil when no embedding could be
    # produced (no key, timeout, non-200, unparsable body). Never raises.
    def embed(text)
      return nil unless available? && text.present?

      # Key goes in a header, never the query string: URLs end up in access
      # logs, proxy traces and exception messages (WebMock printed it into test
      # output), and a leaked key is a billable secret.
      uri = URI(ENDPOINT)
      req = Net::HTTP::Post.new(uri, "content-type" => "application/json",
                                     "x-goog-api-key" => @api_key)
      req.body = JSON.generate(
        model: "models/gemini-embedding-001",
        content: { parts: [ { text: text } ] },
        outputDimensionality: DIMENSIONS
      )

      response = Net::HTTP.start(
        uri.host, uri.port, use_ssl: true,
        open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS
      ) { |http| http.request(req) }

      return nil unless response.code.to_i == 200

      JSON.parse(response.body).dig("embedding", "values")
    rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET,
           SocketError, JSON::ParserError => e
      Rails.logger.warn("Search::Embedder: #{e.class} — #{e.message}")
      nil
    end
  end
end
