require "net/http"

module Chat
  # Wraps the Gemini generateContent endpoint that drives the shopkeeper's
  # tool loop. Same posture as Search::Embedder: unavailable without a key,
  # a bounded timeout, and any network/parse/non-200 failure degrades to nil
  # rather than raising — a provider hiccup must not 500 a chat request.
  class Gemini
    ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent".freeze
    TIMEOUT_SECONDS = 15
    MAX_RESPONSE_BYTES = 32.kilobytes

    def initialize(api_key: ENV["GOOGLE_GENERATIVE_AI_API_KEY"])
      @api_key = api_key
    end

    def available?
      @api_key.present?
    end

    # turns: the running conversation as an Array of {"role"=>, "parts"=>}
    # hashes (Gemini's own wire shape). tools: an Array of functionDeclaration
    # hashes. => the model's candidate parts (Array of {"text"=>...} /
    # {"functionCall"=>...} hashes), or nil when no response could be
    # produced. Never raises.
    def generate(turns:, tools:, system_instruction:)
      return nil unless available?

      # Key goes in a header, never the query string: URLs end up in access
      # logs, proxy traces and exception messages.
      uri = URI(ENDPOINT)
      req = Net::HTTP::Post.new(uri, "content-type" => "application/json",
                                     "x-goog-api-key" => @api_key)
      req.body = JSON.generate(
        system_instruction: { parts: [ { text: system_instruction } ] },
        contents: turns,
        tools: [ { functionDeclarations: tools } ]
      )

      response = Net::HTTP.start(
        uri.host, uri.port, use_ssl: true,
        open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS
      ) { |http| http.request(req) }

      return nil unless response.code.to_i == 200
      return nil if response.body.bytesize > MAX_RESPONSE_BYTES

      JSON.parse(response.body).dig("candidates", 0, "content", "parts")
    rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET,
           SocketError, JSON::ParserError => e
      Rails.logger.warn("Chat::Gemini: #{e.class} — #{e.message}")
      nil
    end
  end
end
