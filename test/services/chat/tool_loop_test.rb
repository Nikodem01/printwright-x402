require "test_helper"
require "webmock/minitest"

class Chat::ToolLoopTest < ActiveSupport::TestCase
  GEMINI = %r{\Ahttps://generativelanguage\.googleapis\.com/v1beta/models/gemini-3\.1-flash-lite:generateContent}

  setup do
    ENV["CHAT_PURCHASES_ENABLED"] = "true"
    ENV["CHAT_MAX_SPEND_CENTS"] = "500"
    ENV["CHAT_DAILY_SPEND_CENTS"] = "1000"
  end

  teardown do
    ENV.delete("CHAT_PURCHASES_ENABLED")
    ENV.delete("CHAT_MAX_SPEND_CENTS")
    ENV.delete("CHAT_DAILY_SPEND_CENTS")
  end

  test "executes a functionCall, echoes it and the result back, then returns the model's text" do
    thought_signature = "opaque-thought-signature"
    final_thought_signature = "opaque-final-thought-signature"
    function_call_id = "call-search-1"
    call_parts = [
      { "text" => "I'll check the catalog." },
      {
        "functionCall" => {
          "name" => "search_models", "args" => { "query" => "cable" }, "id" => function_call_id
        },
        "thoughtSignature" => thought_signature
      }
    ]
    final_parts = [
      { "text" => "We have a " },
      { "text" => "Cable Clip.", "thoughtSignature" => final_thought_signature }
    ]
    request_bodies = []
    stub_request(:post, GEMINI).with { |request|
      request_bodies << JSON.parse(request.body)
      true
    }.to_return(
      { body: { candidates: [ { content: { parts: call_parts } } ] }.to_json,
        headers: { "content-type" => "application/json" } },
      { body: { candidates: [ { content: { parts: final_parts } } ] }.to_json,
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

    call_turn = result.turns.find { |turn| turn["parts"].any? { |part| part["functionCall"] } }
    assert_equal call_parts, call_turn["parts"]

    echoed_call = request_bodies.fetch(1).fetch("contents").find do |turn|
      turn["role"] == "model" && turn["parts"].any? { |part| part.dig("functionCall", "name") == "search_models" }
    end
    assert_equal call_parts, echoed_call["parts"]

    response_turn = result.turns.find { |turn| turn["parts"].first["functionResponse"] }
    assert_equal function_call_id, response_turn.dig("parts", 0, "functionResponse", "id")
    assert_equal "Cable Clip",
      response_turn.dig("parts", 0, "functionResponse", "response", :models, 0, :title)

    assert_equal final_parts, result.turns.last["parts"]
  end

  test "executes parallel calls and groups ordered responses with their ids into one user turn" do
    call_parts = [
      { "text" => "Checking both." },
      { "functionCall" => {
        "name" => "search_models", "args" => { "query" => "clip" }, "id" => "search-id"
      }, "thoughtSignature" => "search-signature" },
      { "functionCall" => {
        "name" => "get_model", "args" => { "id" => "7" }, "id" => "model-id"
      }, "thoughtSignature" => "model-signature" }
    ]
    request_bodies = []
    stub_request(:post, GEMINI).with { |request|
      request_bodies << JSON.parse(request.body)
      true
    }.to_return(
      { body: { candidates: [ { content: { parts: call_parts } } ] }.to_json,
        headers: { "content-type" => "application/json" } },
      { body: { candidates: [ { content: { parts: [ { text: "Done." } ] } } ] }.to_json,
        headers: { "content-type" => "application/json" } }
    )
    stub_request(:get, "http://localhost:3000/api/v1/models?q=clip").to_return(
      body: { models: [], count: 0 }.to_json,
      headers: { "content-type" => "application/json" }
    )
    stub_request(:get, "http://localhost:3000/api/v1/models/7").to_return(
      body: { id: 7, title: "Clip", slug: "clip", license_offers: [] }.to_json,
      headers: { "content-type" => "application/json" }
    )

    result = Chat::ToolLoop.new(
      turns: [ { "role" => "user", "parts" => [ { "text" => "check" } ] } ],
      client: Chat::Gemini.new(api_key: "k")
    ).run

    assert_equal call_parts, result.turns.fetch(1).fetch("parts")
    response_turn = result.turns.fetch(2)
    assert_equal "user", response_turn["role"]
    assert_equal %w[search_models get_model],
      response_turn["parts"].map { |part| part.dig("functionResponse", "name") }
    assert_equal %w[search-id model-id],
      response_turn["parts"].map { |part| part.dig("functionResponse", "id") }
    assert_equal 2, response_turn["parts"].length

    echoed_responses = request_bodies.fetch(1).fetch("contents").fetch(2)
    assert_equal JSON.parse(JSON.generate(response_turn)), echoed_responses
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
    assert_equal "user", result.turns[-2]["role"]
    assert_equal "search_models", result.turns[-2].dig("parts", 0, "functionResponse", "name")
    assert_equal Chat::ToolLoop::MAX_ROUNDS,
      result.turns.count { |turn| turn["parts"].any? { |part| part["functionResponse"] } }
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
    result = nil
    assert_no_difference("Purchase.count") do
      result = Chat::ToolLoop.new(turns: turns, client: Chat::Gemini.new(api_key: "k")).run
    end

    response_turn = result.turns.find { |t| t["parts"].first["functionResponse"] }
    assert_equal "unknown_tool", response_turn.dig("parts", 0, "functionResponse", "response", :error)
    assert_not_requested :get, %r{/download}
    assert_not_requested :post, %r{/sign|/verify|/settle}
  end

  test "propose_purchase produces approval data but makes no payment request" do
    stub_request(:post, GEMINI).to_return(
      { body: { candidates: [ { content: { parts: [
          { functionCall: { name: "propose_purchase", args: { id: "5", license_kind: "personal" }, id: "p1" } }
        ] } } ] }.to_json, headers: { "content-type" => "application/json" } },
      { body: { candidates: [ { content: { parts: [ { text: "Use the approval card to continue." } ] } } ] }.to_json,
        headers: { "content-type" => "application/json" } }
    )
    stub_request(:get, "http://localhost:3000/api/v1/models/5").to_return(
      body: { id: 5, title: "Cable Clip", license_offers: [ { kind: "personal", price_cents: 90 } ] }.to_json,
      headers: { "content-type" => "application/json" }
    )

    result = Chat::ToolLoop.new(
      turns: [ { "role" => "user", "parts" => [ { "text" => "Buy model 5 personal." } ] } ],
      client: Chat::Gemini.new(api_key: "k")
    ).run

    response = result.turns.find { |turn| turn.dig("parts", 0, "functionResponse", "name") == "propose_purchase" }
    assert response.dig("parts", 0, "functionResponse", "response", :approval_required)
    assert_not_requested :get, %r{/download}
    assert_not_requested :post, %r{/sign|/verify|/settle}
  end
end
