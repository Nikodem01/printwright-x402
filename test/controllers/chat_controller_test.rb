require "test_helper"
require "webmock/minitest"

class ChatControllerTest < ActionDispatch::IntegrationTest
  GEMINI = %r{\Ahttps://generativelanguage\.googleapis\.com/v1beta/models/gemini-3\.1-flash-lite:generateContent}

  setup do
    ENV["CHAT_PURCHASES_ENABLED"] = "false"
    ENV["CHAT_MAX_SPEND_CENTS"] = "0"
    ENV["CHAT_DAILY_SPEND_CENTS"] = "0"
    ENV["CHAT_DAILY_MESSAGE_LIMIT"] = "500"
    ENV["CHAT_DAILY_VISITOR_MESSAGE_LIMIT"] = "25"
    ENV["CHAT_DAILY_PROVIDER_CALL_LIMIT"] = "500"
  end

  teardown do
    ENV.delete("CHAT_PURCHASES_ENABLED")
    ENV.delete("CHAT_MAX_SPEND_CENTS")
    ENV.delete("CHAT_DAILY_SPEND_CENTS")
    ENV.delete("CHAT_DAILY_MESSAGE_LIMIT")
    ENV.delete("CHAT_DAILY_VISITOR_MESSAGE_LIMIT")
    ENV.delete("CHAT_DAILY_PROVIDER_CALL_LIMIT")
    RateLimitStore.backend = nil
  end

  test "the chat page renders publicly, with no session required" do
    get chat_path
    assert_response :success
    assert_select "form#chat_form"
    assert_select "#chat_empty_state"
    assert_select "[data-controller='chat-prompt']"
    assert_select "button[data-action='chat-prompt#choose']", 2
    assert_select "button[data-chat-prompt-message-param*='buy']", minimum: 1
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
      { body: { candidates: [ { content: { parts: [ { text: "We have a Cable Clip for 1.50 USDC." } ] } } ] }.to_json,
        headers: { "content-type" => "application/json" } }
    )
    stub_request(:get, %r{\Ahttp://localhost:3000/api/v1/models\?}).to_return(
      body: { models: [ {
        "id" => model.id, "title" => model.title, "slug" => model.slug,
        "url" => "http://localhost:3000/api/v1/models/#{model.id}",
        "render_url" => "http://localhost:3000/cable-clip.png",
        "license_offers" => [ { "kind" => "personal", "price_cents" => 150, "currency" => "USDC" } ]
      } ], count: 1 }.to_json,
      headers: { "content-type" => "application/json" }
    )

    post chat_path, params: { message: "anything to tidy cables on my desk?" }, as: :turbo_stream

    assert_turbo_stream action: "append", target: "chat_messages" do
      assert_select "code.mono", text: /search_models\(query: "cable"\)/
      assert_select ".chat-model-result[href=?]", model_page_path(model.slug), text: /Cable Clip.*1\.50 USDC/
      assert_select ".chat-model-result img[src=?]", "http://localhost:3000/cable-clip.png"
      assert_select ".chat-msg-assistant", text: /Cable Clip.*1\.50 USDC/
    end
    assert_turbo_stream action: "replace", target: "chat_form"
  ensure
    ENV.delete("GOOGLE_GENERATIVE_AI_API_KEY")
  end

  test "renders an out-of-scope assistant response without inventing a tool action" do
    ENV["GOOGLE_GENERATIVE_AI_API_KEY"] = "test-key"
    stub_request(:post, GEMINI).to_return(
      body: { candidates: [ { content: { parts: [
        { text: "I can help with this marketplace catalog, but not that request." }
      ] } } ] }.to_json,
      headers: { "content-type" => "application/json" }
    )

    post chat_path, params: { message: "write my tax return" }, as: :turbo_stream

    assert_turbo_stream action: "append", target: "chat_messages" do
      assert_select ".chat-msg-assistant", text: /marketplace catalog/
    end
  ensure
    ENV.delete("GOOGLE_GENERATIVE_AI_API_KEY")
  end

  test "a blank message is a no-op, not an error" do
    post chat_path, params: { message: "   " }, as: :turbo_stream
    assert_response :success
    assert_no_turbo_stream action: "append", target: "chat_messages"
  end

  test "reset deletes the server-side conversation and starts fresh" do
    get chat_path
    conversation = ChatConversation.find(session[:chat_conversation_id])
    conversation.update!(
      turns: [ { "role" => "user", "parts" => [ { "text" => "old question" } ] } ],
      purchase_proposal: proposal
    )

    delete chat_path, headers: { "HTTP_REFERER" => chat_url }

    assert_redirected_to chat_url
    assert_nil session[:chat_conversation_id]
    assert_not ChatConversation.exists?(conversation.id)

    follow_redirect!
    assert_select "#chat_empty_state"
    assert_select ".chat-msg", count: 0
    assert_select "button", text: "Reset chat", count: 1
  end

  test "a long conversation persists in the database while the cookie keeps only its id" do
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
    conversation = ChatConversation.find(session[:chat_conversation_id])
    assert_nil session[:chat_turns]
    assert_operator JSON.generate(conversation.turns).bytesize, :>, 2500
    assert_operator JSON.generate(conversation.turns).bytesize, :<=, ChatConversation::MAX_TURNS_BYTES
    assert_operator response.headers["Set-Cookie"].to_s.bytesize, :<, 4096
  ensure
    ENV.delete("GOOGLE_GENERATIVE_AI_API_KEY")
  end


  test "a proposal card uses canonical tool data and creates no purchase before approval" do
    enable_purchases
    ENV["GOOGLE_GENERATIVE_AI_API_KEY"] = "test-key"
    stub_request(:post, GEMINI).to_return(
      { body: { candidates: [ { content: { parts: [
          { functionCall: { name: "propose_purchase", args: { id: "5", license_kind: "personal" }, id: "p1" } }
        ] } } ] }.to_json, headers: { "content-type" => "application/json" } },
      { body: { candidates: [ { content: { parts: [ { text: "Please use the approval card." } ] } } ] }.to_json,
        headers: { "content-type" => "application/json" } }
    )
    stub_request(:get, "http://localhost:3000/api/v1/models/5").to_return(
      body: { id: 5, title: "Canonical Clip", license_offers: [ { kind: "personal", price_cents: 90 } ] }.to_json,
      headers: { "content-type" => "application/json" }
    )

    assert_no_difference("Purchase.count") do
      post chat_path, params: { message: "Buy model 5 personal." }, as: :turbo_stream
    end

    assert_turbo_stream action: "replace", target: "chat_purchase" do
      assert_select ".chat-purchase-card", text: /Canonical Clip/
      assert_select "button", text: /Approve and buy.*0\.90 USDC/
    end
    assert_not_requested :get, %r{/download}
    assert_not_requested :post, %r{/sign|/verify|/settle}
  ensure
    ENV.delete("GOOGLE_GENERATIVE_AI_API_KEY")
  end

  test "approval ignores forged purchase parameters and returns the stored cap-checked quote" do
    enable_purchases
    get chat_path
    conversation = ChatConversation.find(session[:chat_conversation_id])
    conversation.update!(purchase_proposal: proposal)
    quote = payment_required
    stub_request(:get, "http://www.example.com#{proposal['purchase_path']}").to_return(
      status: 402, body: quote.to_json, headers: { "content-type" => "application/json" }
    )

    post approve_chat_purchase_path,
      params: { model_id: 999, license_kind: "commercial_unit", price_cents: 1, amount: "1" }, as: :json

    assert_response :success
    assert_equal "http://www.example.com#{proposal['purchase_path']}", response.parsed_body["purchase_url"]
    assert_equal [ "900000" ], response.parsed_body.dig("payment_required", "accepts").pluck("amount")
    assert response.parsed_body["purchase_intent"].present?
    assert_equal 90, conversation.reload.approved_spend_cents
  end

  test "oversized input is rejected before Gemini and chat requests are rate limited" do
    ENV["GOOGLE_GENERATIVE_AI_API_KEY"] = "test-key"
    post chat_path, params: { message: "x" * (ChatController::MAX_MESSAGE_BYTES + 1) }, as: :turbo_stream
    assert_response :success
    assert_match(/too long/i, ChatConversation.find(session[:chat_conversation_id]).turns.last.dig("parts", 0, "text"))
    assert_not_requested :post, GEMINI

    RateLimitStore.backend = ActiveSupport::Cache::MemoryStore.new
    10.times { post chat_path, params: { message: "" }, as: :turbo_stream }
    post chat_path, params: { message: "" }, as: :turbo_stream
    assert_response :too_many_requests
    assert_equal "60", response.headers["Retry-After"]
  ensure
    ENV.delete("GOOGLE_GENERATIVE_AI_API_KEY")
  end

  test "the per-visitor daily limit stops one person consuming the shared allowance" do
    ENV["GOOGLE_GENERATIVE_AI_API_KEY"] = "test-key"
    ENV["CHAT_DAILY_VISITOR_MESSAGE_LIMIT"] = "1"
    RateLimitStore.backend = ActiveSupport::Cache::MemoryStore.new
    stub_request(:post, GEMINI).to_return(
      body: { candidates: [ { content: { parts: [ { text: "First answer." } ] } } ] }.to_json,
      headers: { "content-type" => "application/json" }
    )

    post chat_path, params: { message: "first" }, as: :turbo_stream
    post chat_path, params: { message: "second" }, as: :turbo_stream

    assert_response :success
    assert_match(/fair-use limit/i, ChatConversation.find(session[:chat_conversation_id]).turns.last.dig("parts", 0, "text"))
    assert_requested :post, GEMINI, times: 1
  ensure
    ENV.delete("GOOGLE_GENERATIVE_AI_API_KEY")
  end

  test "the global provider-call budget fails closed without another Gemini call" do
    ENV["GOOGLE_GENERATIVE_AI_API_KEY"] = "test-key"
    ENV["CHAT_DAILY_PROVIDER_CALL_LIMIT"] = "1"
    RateLimitStore.backend = ActiveSupport::Cache::MemoryStore.new
    stub_request(:post, GEMINI).to_return(
      body: { candidates: [ { content: { parts: [
        { functionCall: { name: "search_models", args: { query: "cable" } } }
      ] } } ] }.to_json,
      headers: { "content-type" => "application/json" }
    )
    stub_request(:get, %r{\Ahttp://localhost:3000/api/v1/models\?}).to_return(
      body: { models: [], count: 0 }.to_json,
      headers: { "content-type" => "application/json" }
    )

    post chat_path, params: { message: "find a cable organizer" }, as: :turbo_stream

    assert_response :success
    assert_match(/shared daily assistant budget/i,
      ChatConversation.find(session[:chat_conversation_id]).turns.last.dig("parts", 0, "text"))
    assert_requested :post, GEMINI, times: 1
  ensure
    ENV.delete("GOOGLE_GENERATIVE_AI_API_KEY")
  end

  private

  def enable_purchases
    ENV["CHAT_PURCHASES_ENABLED"] = "true"
    ENV["CHAT_MAX_SPEND_CENTS"] = "500"
    ENV["CHAT_DAILY_SPEND_CENTS"] = "1000"
  end

  def proposal
    {
      "nonce" => "controller-proposal",
      "state" => "pending",
      "model_id" => 5,
      "title" => "Stored Clip",
      "license_kind" => "personal",
      "price_cents" => 90,
      "display_price" => "0.90 USDC",
      "purchase_path" => "/api/v1/models/5/download?license=personal",
      "expires_at" => 10.minutes.from_now.iso8601
    }
  end

  def payment_required
    {
      x402Version: 2,
      resource: { url: "http://www.example.com#{proposal['purchase_path']}" },
      accepts: [
        { scheme: "exact", network: X402::Requirements.network, amount: "900000",
          asset: X402::Requirements.usdc_asset, payTo: "0.0.123", extra: { feePayer: "0.0.456" } }
      ]
    }
  end
end
