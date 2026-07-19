require "net/http"

module Chat
  # The chat's only path to catalog data — the same public HTTP API an
  # outside agent would call, never ActiveRecord directly. That boundary is
  # the whole point of the shopkeeper door: it proves the public API is good
  # enough to build on.
  module Tools
    BASE_URL = ENV.fetch("PRINTWRIGHT_URL", "http://localhost:3000")
    TIMEOUT_SECONDS = 5
    # Trimmed hard: a chat answer names a couple of options, not the catalog —
    # and every extra model is tokens the model has to read before answering.
    RESULT_LIMIT = 5

    module_function

    def search_models(query)
      return { error: "missing_query" } if query.blank?

      body = get("/api/v1/models", q: query)
      return { error: "search_unavailable" } unless body

      models = Array(body["models"]).first(RESULT_LIMIT).map { |m| summarize(m) }
      { models: models, count: models.length }
    end

    def get_model(id)
      return { error: "missing_id" } if id.blank?

      body = get("/api/v1/models/#{id}")
      return { error: "not_found", message: "no model with that id" } unless body

      summarize(body, detailed: true)
    end

    # This tool prepares trusted display data for a separate human approval
    # step. It never requests a 402 quote, contacts a wallet, or submits a
    # payment. Catalog prose is deliberately omitted from the proposal.
    def propose_purchase(id, license_kind)
      return { error: "purchases_disabled" } unless Chat::PurchasePolicy.enabled?
      return { error: "invalid_model_id" } unless id.to_s.match?(/\A[1-9]\d*\z/)

      kind = license_kind.to_s
      return { error: "invalid_license" } unless kind.match?(/\A[a-z_]+\z/)

      body = get("/api/v1/models/#{id}")
      return { error: "not_found" } unless body

      offer = Array(body["license_offers"]).find { |candidate| candidate["kind"] == kind }
      return { error: "offer_not_found" } unless offer

      price_cents = strict_positive_integer(offer["price_cents"])
      return { error: "invalid_price" } unless price_cents
      if price_cents > Chat::PurchasePolicy.max_spend_cents
        return { error: "spend_cap_exceeded", max_spend_cents: Chat::PurchasePolicy.max_spend_cents }
      end

      {
        approval_required: true,
        proposal: {
          model_id: id.to_i,
          title: body["title"].to_s.first(200),
          license_kind: kind,
          price_cents: price_cents,
          display_price: format("$%.2f", price_cents / 100.0),
          purchase_path: "/api/v1/models/#{id}/download?#{URI.encode_www_form(license: kind)}",
          expires_at: Chat::PurchasePolicy::PROPOSAL_LIFETIME.from_now.iso8601
        }
      }
    end

    # Trimmed to what a chat answer actually needs — the full API payload
    # (files, license terms text, hedera account id, ...) would waste tokens
    # and bury the answer in noise.
    #
    # price_cents is always US cents, regardless of settlement currency (see
    # ApplicationHelper#offer_price) — handing that raw over unlabeled once
    # had the model read 90 price_cents as "90 USDC" instead of $0.90.
    # Formatting it as a dollar string here is what keeps the price honest.
    def summarize(model, detailed: false)
      summary = {
        id: model["id"],
        title: model["title"],
        designer: model.dig("designer", "name"),
        license_offers: Array(model["license_offers"]).map do |offer|
          { kind: offer["kind"], price: format("$%.2f", offer["price_cents"].to_i / 100.0), settles_in: offer["currency"] }
        end,
        # The API's own "url" field is the JSON endpoint (an agent's door) — a
        # human told to "visit the model's page" needs the storefront page,
        # where there's actually something to look at and a buy button.
        url: "#{BASE_URL}/models/#{model['slug']}"
      }
      summary[:description] = model["description"] if detailed && model["description"].present?
      summary
    end

    def get(path, params = {})
      uri = URI("#{BASE_URL}#{path}")
      uri.query = URI.encode_www_form(params) if params.present?

      response = Net::HTTP.start(
        uri.host, uri.port, use_ssl: uri.scheme == "https",
        open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS
      ) { |http| http.get(uri) }

      return nil unless response.code.to_i == 200

      JSON.parse(response.body)
    rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET,
           SocketError, JSON::ParserError => e
      Rails.logger.warn("Chat::Tools: #{e.class} — #{e.message}")
      nil
    end


    def strict_positive_integer(value)
      string = value.to_s
      string.match?(/\A[1-9]\d*\z/) ? string.to_i : nil
    end
    private_class_method :strict_positive_integer
  end
end
