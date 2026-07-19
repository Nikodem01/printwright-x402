module ChatHelper
  # A stored turn is one of: a user question, a model tool call, a tool
  # result (not shown — the call above it already made the trace visible),
  # or the model's prose answer.
  def chat_turn_kind(turn)
    parts = Array(turn["parts"])
    return :tool_call if parts.any? { |part| part.key?("functionCall") }
    return :tool_response if parts.any? { |part| part.key?("functionResponse") }
    turn["role"] == "user" ? :user_message : :assistant_message
  end

  def chat_turn_text(turn)
    Array(turn["parts"]).filter_map { |part| part["text"] }.join
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
