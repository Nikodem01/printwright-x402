module ChatHelper
  # A stored turn is one of: a user question, a model tool call, a tool
  # result (not shown — the call above it already made the trace visible),
  # or the model's prose answer.
  def chat_turn_kind(turn)
    part = turn["parts"]&.first
    return :tool_call if part&.key?("functionCall")
    return :tool_response if part&.key?("functionResponse")
    turn["role"] == "user" ? :user_message : :assistant_message
  end

  def chat_turn_text(turn)
    turn["parts"]&.first&.dig("text")
  end

  # e.g. search_models(query: "cable organizer") — the visible tool trace:
  # which tool ran, with what arguments, before the answer.
  def chat_tool_call_label(turn)
    call = turn["parts"].first["functionCall"]
    args = (call["args"] || {}).map { |k, v| "#{k}: #{v.inspect}" }.join(", ")
    "#{call['name']}(#{args})"
  end
end
