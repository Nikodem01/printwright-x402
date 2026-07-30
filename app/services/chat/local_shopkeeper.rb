module Chat
  # A small, deterministic shopkeeper for README-only local runs. It supports
  # catalog search and explicit purchase proposals; open-ended recommendations
  # remain the optional Gemini path.
  class LocalShopkeeper
    Result = Struct.new(:turns, keyword_init: true)

    def initialize(turns:)
      @turns = turns
    end

    def run(text:)
      purchase_request?(text) ? propose(text) : search(text)
      Result.new(turns: @turns)
    end

    private

    def search(text)
      query = search_query(text)
      response = Chat::Tools.search_models(query)
      models = Array(response[:models] || response["models"])
      answer =
        if response[:error] || response["error"]
          "I couldn't reach the catalog just now. Please try again."
        elsif models.empty?
          "I couldn't find a catalog match for “#{query}”. Try a shorter product description."
        elsif models.one?
          "I found one catalog match. To buy it, name it and say personal or commercial-unit license."
        else
          "I found #{models.length} catalog matches. To buy one, name it and say personal or commercial-unit license."
        end

      append_tool("search_models", { "query" => query }, response, answer)
    end

    def propose(text)
      model = referenced_model(text)
      return append_answer("Search the catalog first, then name the model you want to buy.") unless model

      kind = license_kind(text)
      return append_answer("Say whether you want the personal or commercial-unit license.") unless kind

      model_id = model[:id] || model["id"]
      response = Chat::Tools.propose_purchase(model_id.to_s, kind)
      answer =
        if response[:approval_required] || response["approval_required"]
          "Review the approval card below. Nothing is signed or spent until you press its button."
        else
          proposal_error(response)
        end

      append_tool(
        "propose_purchase",
        { "id" => model_id.to_s, "license_kind" => kind },
        response,
        answer
      )
    end

    def append_tool(name, args, response, answer)
      @turns << {
        "role" => "model",
        "parts" => [ { "functionCall" => { "name" => name, "args" => args } } ]
      }
      @turns << {
        "role" => "user",
        "parts" => [ { "functionResponse" => { "name" => name, "response" => response } } ]
      }
      append_answer(answer)
    end

    def append_answer(text)
      @turns << { "role" => "model", "parts" => [ { "text" => text } ] }
    end

    def purchase_request?(text)
      text.match?(/\b(?:buy|purchase)\b/i)
    end

    def search_query(text)
      query = text.sub(
        /\A\s*(?:please\s+)?(?:find(?:\s+me)?|search(?:\s+for)?|show\s+me|look\s+for)\s+/i,
        ""
      ).strip
      query = query.delete_suffix("?").strip
      query.presence || text.strip
    end

    def referenced_model(text)
      models = prior_models
      normalized = text.downcase
      models.find do |model|
        title = (model[:title] || model["title"]).to_s.downcase
        slug = (model[:slug] || model["slug"]).to_s.downcase.tr("-", " ")
        id = (model[:id] || model["id"]).to_s
        normalized.include?(title) || normalized.include?(slug) ||
          normalized.match?(/\bmodel\s+#{Regexp.escape(id)}\b/)
      end || models.one? && models.first
    end

    def prior_models
      @turns.flat_map do |turn|
        Array(turn["parts"]).flat_map do |part|
          function_response = part["functionResponse"]
          next [] unless function_response&.fetch("name", nil).in?(%w[search_models get_model])

          response = function_response["response"] || {}
          function_response["name"] == "search_models" ? Array(response[:models] || response["models"]) : [ response ]
        end
      end.uniq { |model| model[:id] || model["id"] }
    end

    def license_kind(text)
      return "commercial_unit" if text.match?(/\bcommercial(?:[-\s]+unit)?\b/i)
      "personal" if text.match?(/\bpersonal\b/i)
    end

    def proposal_error(response)
      error = (response[:error] || response["error"]).to_s
      case error
      when "purchases_disabled"
        "Chat purchases are disabled on this server. Enable them and set positive spend caps first."
      when "spend_cap_exceeded"
        "That offer exceeds this server's chat purchase cap."
      when "offer_not_found"
        "That model does not have the requested license offer."
      else
        "I couldn't prepare that purchase proposal. Search again and retry."
      end
    end
  end
end
