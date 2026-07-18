require "test_helper"
require "webmock/minitest"

class ChatControllerTest < ActionDispatch::IntegrationTest
  GEMINI = %r{\Ahttps://generativelanguage\.googleapis\.com/v1beta/models/gemini-2\.5-flash:generateContent}

  test "the chat page renders publicly, with no session required" do
    get chat_path
    assert_response :success
    assert_select "form#chat_form"
    assert_select "#chat_empty_state"
  end

  test "asking a question shows the tool trace before the answer, and the prices match the API" do
    ENV["GOOGLE_GENERATIVE_AI_API_KEY"] = "test-key"
    model = Model3d.create!(
      designer: designers(:one), title: "Cable Clip", slug: "cable-clip-#{SecureRandom.hex(4)}",
      status: "published", file_hash: "sha256:#{'a' * 64}"
    )
    model.license_offers.create!(kind: "personal", price_cents: 150, terms_md: "T.")

    stub_request(:post, GEMINI).to_return(
      { body: { candidates: [ { content: { parts: [
          { functionCall: { name: "search_models", args: { query: "cable" } } }
        ] } } ] }.to_json, headers: { "content-type" => "application/json" } },
      { body: { candidates: [ { content: { parts: [ { text: "We have a Cable Clip for $1.50." } ] } } ] }.to_json,
        headers: { "content-type" => "application/json" } }
    )
    stub_request(:get, %r{\Ahttp://localhost:3000/api/v1/models\?}).to_return(
      body: { models: [ {
        "id" => model.id, "title" => model.title, "slug" => model.slug,
        "url" => "http://localhost:3000/api/v1/models/#{model.id}",
        "license_offers" => [ { "kind" => "personal", "price_cents" => 150, "currency" => "USDC" } ]
      } ], count: 1 }.to_json,
      headers: { "content-type" => "application/json" }
    )

    post chat_path, params: { message: "anything to tidy cables on my desk?" }, as: :turbo_stream

    assert_turbo_stream action: "append", target: "chat_messages" do
      assert_select "code.mono", text: /search_models\(query: "cable"\)/
      assert_select ".chat-msg-assistant", text: /Cable Clip.*\$1\.50/
    end
    assert_turbo_stream action: "replace", target: "chat_form"
  ensure
    ENV.delete("GOOGLE_GENERATIVE_AI_API_KEY")
  end

  test "declines a buy request honestly instead of pretending to purchase" do
    ENV["GOOGLE_GENERATIVE_AI_API_KEY"] = "test-key"
    stub_request(:post, GEMINI).to_return(
      body: { candidates: [ { content: { parts: [
        { text: "Buying isn't wired up in chat yet — visit the model's page to buy it." }
      ] } } ] }.to_json,
      headers: { "content-type" => "application/json" }
    )

    post chat_path, params: { message: "buy me the cheapest one" }, as: :turbo_stream

    assert_turbo_stream action: "append", target: "chat_messages" do
      assert_select ".chat-msg-assistant", text: /isn't wired up/
    end
  ensure
    ENV.delete("GOOGLE_GENERATIVE_AI_API_KEY")
  end

  test "a blank message is a no-op, not an error" do
    post chat_path, params: { message: "   " }, as: :turbo_stream
    assert_response :success
    assert_no_turbo_stream action: "append", target: "chat_messages"
  end

  test "a long conversation is trimmed so the session cookie never overflows" do
    ENV["GOOGLE_GENERATIVE_AI_API_KEY"] = "test-key"
    # A realistic-sized answer, repeated across many exchanges, is exactly
    # what blew the ~4KB cookie budget in manual testing (CookieOverflow).
    long_answer = "Yes, we have several options for that. " * 15
    stub_request(:post, GEMINI).to_return(
      body: { candidates: [ { content: { parts: [ { text: long_answer } ] } } ] }.to_json,
      headers: { "content-type" => "application/json" }
    )

    assert_nothing_raised do
      20.times { |i| post chat_path, params: { message: "question #{i}" }, as: :turbo_stream }
    end
    assert_response :success
    assert_operator JSON.generate(session[:chat_turns]).bytesize, :<=, ChatController::MAX_SESSION_BYTES
  ensure
    ENV.delete("GOOGLE_GENERATIVE_AI_API_KEY")
  end
end
