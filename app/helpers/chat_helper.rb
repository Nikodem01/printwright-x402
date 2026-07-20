module ChatHelper
  # A stored turn is one of: a user question, a model tool call, a tool
  # result, or the model's prose answer.
  def chat_turn_kind(turn)
    parts = Array(turn["parts"])
    return :tool_call if parts.any? { |part| part.key?("functionCall") }
    return :tool_response if parts.any? { |part| part.key?("functionResponse") }
    turn["role"] == "user" ? :user_message : :assistant_message
  end

  def chat_turn_text(turn)
    Array(turn["parts"]).filter_map { |part| part["text"] }.join
  end

  # The system prompt asks Gemini for plain text, but this keeps harmless
  # Markdown emphasis/list markers from leaking into the interface if the
  # provider ignores that presentation instruction.
  def chat_assistant_text(turn)
    chat_turn_text(turn).gsub("**", "").gsub(/^\s*\*\s+/, "• ")
  end

  # Function responses can contain symbol keys immediately after the tool
  # loop and string keys after their JSONB round-trip. Normalize both shapes
  # here, and only expose actual catalog lookup results as product cards.
  def chat_catalog_results(turn)
    Array(turn["parts"]).flat_map do |part|
      function_response = part["functionResponse"] || part[:functionResponse]
      next [] unless function_response

      function_response = function_response.with_indifferent_access
      payload = function_response[:response]
      next [] unless payload.respond_to?(:with_indifferent_access)

      payload = payload.with_indifferent_access
      case function_response[:name]
      when "search_models"
        Array(payload[:models])
      when "get_model"
        payload[:id].present? ? [ payload ] : []
      else
        []
      end
    end.map(&:with_indifferent_access).uniq { |model| model[:id] }
  end

  # Older stored conversations predate the explicit slug field but already
  # carry the website URL. Reduce either shape to a local storefront route.
  def chat_catalog_model_path(model)
    model = model.with_indifferent_access
    return model_page_path(model[:slug]) if model[:slug].present?

    path = URI.parse(model[:url].to_s).path
    path if path.match?(%r{\A/models/[^/]+\z})
  rescue URI::InvalidURIError
    nil
  end

  # e.g. search_models(query: "cable organizer") — the visible tool trace:
  # which tool ran, with what arguments, before the answer.
  def chat_tool_call_label(turn)
    Array(turn["parts"]).filter_map { |part|
      call = part["functionCall"]
      next unless call

      args = (call["args"] || {}).map { |key, value| "#{key}: #{value.inspect}" }.join(", ")
      "#{call['name']}(#{args})"
    }.join("; ")
  end
end
