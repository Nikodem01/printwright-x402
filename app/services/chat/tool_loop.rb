module Chat
  # Server-side Gemini tool loop for the shopkeeper chat: send the
  # conversation -> if the model asks for a tool, run it against our own
  # public API -> echo the call and its result back -> ask again -> repeat
  # until the model answers in text.
  #
  # `turns` is Gemini's own wire shape end to end (an Array of
  # {"role"=>, "parts"=>} hashes) so it round-trips through the session
  # cookie (JSON) and back into the next request unchanged.
  class ToolLoop
    # A confused model asking for tool after tool must not spin forever —
    # stop and say so honestly instead.
    MAX_ROUNDS = 5

    UNAVAILABLE_MESSAGE = "I couldn't reach the shopkeeper assistant just now — try again in a moment."
    BOUND_MESSAGE = "I wasn't able to finish that within the allowed number of tool calls — " \
                    "try rephrasing your question, maybe more specifically."

    SYSTEM_PROMPT = <<~PROMPT.freeze
      You are the Printwright shopkeeper: a chat assistant for a marketplace of
      licensed 3D-printable models, running on Hedera testnet.

      Ground rules you must never break:
      - Only describe models the search_models / get_model tools actually returned.
        Never invent a model, a price, or a capability.
      - Prices always come from the tool response, never from memory. Each
        license_offer's "price" is already a formatted dollar amount (e.g. "$0.90")
        — quote it exactly as given, don't rescale or reinterpret it.
      - If nothing matches, say so plainly — do not offer the nearest result as if
        it matched.
      - You cannot buy anything in this conversation — purchasing isn't wired up
        into chat yet. If asked to buy or check out, say that honestly and point
        to the model's page (the "url" field from the tool response) instead.
      - This is a Hedera testnet deployment. Never imply real-money commerce.
    PROMPT

    TOOLS = [
      {
        name: "search_models",
        description: "Search the Printwright catalog of licensed 3D-printable models by keyword.",
        parameters: {
          type: "object",
          properties: { query: { type: "string", description: "search text, e.g. 'cable organizer'" } },
          required: [ "query" ]
        }
      },
      {
        name: "get_model",
        description: "Look up one model's full details (description, license offers, prices) by its id.",
        parameters: {
          type: "object",
          properties: { id: { type: "string", description: "the model's id, from a prior search result" } },
          required: [ "id" ]
        }
      }
    ].freeze

    Result = Struct.new(:turns, keyword_init: true)

    def initialize(turns:, client: Chat::Gemini.new)
      @turns = turns
      @client = client
    end

    def run
      return finish(UNAVAILABLE_MESSAGE) unless @client.available?

      MAX_ROUNDS.times do
        parts = @client.generate(turns: @turns, tools: TOOLS, system_instruction: SYSTEM_PROMPT)
        return finish(UNAVAILABLE_MESSAGE) unless parts

        call = parts.find { |p| p["functionCall"] }
        return finish(answer_text(parts)) unless call

        @turns << { "role" => "model", "parts" => [ call ] }
        @turns << { "role" => "user", "parts" => [ { "functionResponse" => {
          "name" => call.dig("functionCall", "name"), "response" => execute(call["functionCall"])
        } } ] }
      end

      finish(BOUND_MESSAGE)
    end

    private

    def answer_text(parts)
      parts.filter_map { |p| p["text"] }.join.presence || "..."
    end

    def finish(text)
      @turns << { "role" => "model", "parts" => [ { "text" => text } ] }
      Result.new(turns: @turns)
    end

    def execute(function_call)
      name = function_call["name"]
      args = function_call["args"] || {}

      case name
      when "search_models" then Chat::Tools.search_models(args["query"])
      when "get_model" then Chat::Tools.get_model(args["id"])
      else { error: "unknown_tool", message: "no such tool: #{name}" }
      end
    rescue => e
      Rails.logger.warn("Chat::ToolLoop: tool #{name} failed — #{e.class}: #{e.message}")
      { error: "tool_failed", message: "the #{name} tool failed" }
    end
  end
end
