require "test_helper"
require "webmock/minitest"

class Chat::ToolLoopTest < ActiveSupport::TestCase
  GEMINI = %r{\Ahttps://generativelanguage\.googleapis\.com/v1beta/models/gemini-2\.5-flash:generateContent}

  test "executes a functionCall, echoes it and the result back, then returns the model's text" do
    stub_request(:post, GEMINI).to_return(
      { body: { candidates: [ { content: { parts: [
          { functionCall: { name: "search_models", args: { query: "cable" } } }
        ] } } ] }.to_json, headers: { "content-type" => "application/json" } },
      { body: { candidates: [ { content: { parts: [ { text: "We have a Cable Clip." } ] } } ] }.to_json,
        headers: { "content-type" => "application/json" } }
    )
    stub_request(:get, "http://localhost:3000/api/v1/models?q=cable").to_return(
      body: { models: [ { "id" => 1, "title" => "Cable Clip", "slug" => "cable-clip",
                          "url" => "http://localhost:3000/api/v1/models/1",
                          "license_offers" => [ { "kind" => "personal", "price_cents" => 100, "currency" => "USDC" } ] } ],
              count: 1 }.to_json,
      headers: { "content-type" => "application/json" }
    )

    turns = [ { "role" => "user", "parts" => [ { "text" => "anything to tidy cables?" } ] } ]
    result = Chat::ToolLoop.new(turns: turns, client: Chat::Gemini.new(api_key: "k")).run

    call_turn = result.turns.find { |t| t["parts"].first["functionCall"] }
    assert_equal "search_models", call_turn.dig("parts", 0, "functionCall", "name")
    assert_equal "cable", call_turn.dig("parts", 0, "functionCall", "args", "query")

    response_turn = result.turns.find { |t| t["parts"].first["functionResponse"] }
    assert_equal "Cable Clip",
      response_turn.dig("parts", 0, "functionResponse", "response", :models, 0, :title)

    assert_equal "We have a Cable Clip.", result.turns.last.dig("parts", 0, "text")
  end

  test "stops after the round-trip bound and says so honestly" do
    stub_request(:post, GEMINI).to_return(
      body: { candidates: [ { content: { parts: [
        { functionCall: { name: "search_models", args: { query: "x" } } }
      ] } } ] }.to_json,
      headers: { "content-type" => "application/json" }
    )
    stub_request(:get, %r{\Ahttp://localhost:3000/api/v1/models})
      .to_return(body: { models: [], count: 0 }.to_json, headers: { "content-type" => "application/json" })

    turns = [ { "role" => "user", "parts" => [ { "text" => "x" } ] } ]
    result = Chat::ToolLoop.new(turns: turns, client: Chat::Gemini.new(api_key: "k")).run

    assert_match(/tool calls/, result.turns.last.dig("parts", 0, "text"))
    assert_requested(:post, GEMINI, times: Chat::ToolLoop::MAX_ROUNDS)
  end

  test "a provider failure degrades to a friendly message instead of raising" do
    stub_request(:post, GEMINI).to_timeout

    turns = [ { "role" => "user", "parts" => [ { "text" => "hi" } ] } ]
    result = Chat::ToolLoop.new(turns: turns, client: Chat::Gemini.new(api_key: "k")).run

    assert_match(/couldn.t reach/i, result.turns.last.dig("parts", 0, "text"))
  end

  test "missing API key degrades to a friendly message without calling Gemini at all" do
    turns = [ { "role" => "user", "parts" => [ { "text" => "hi" } ] } ]
    result = Chat::ToolLoop.new(turns: turns, client: Chat::Gemini.new(api_key: nil)).run

    assert_match(/couldn.t reach/i, result.turns.last.dig("parts", 0, "text"))
    assert_not_requested :post, GEMINI
  end

  test "an unknown tool name returns a recoverable error instead of raising" do
    stub_request(:post, GEMINI).to_return(
      { body: { candidates: [ { content: { parts: [
          { functionCall: { name: "delete_everything", args: {} } }
        ] } } ] }.to_json, headers: { "content-type" => "application/json" } },
      { body: { candidates: [ { content: { parts: [ { text: "I can't do that." } ] } } ] }.to_json,
        headers: { "content-type" => "application/json" } }
    )

    turns = [ { "role" => "user", "parts" => [ { "text" => "delete everything" } ] } ]
    result = Chat::ToolLoop.new(turns: turns, client: Chat::Gemini.new(api_key: "k")).run

    response_turn = result.turns.find { |t| t["parts"].first["functionResponse"] }
    assert_equal "unknown_tool", response_turn.dig("parts", 0, "functionResponse", "response", :error)
  end
end
