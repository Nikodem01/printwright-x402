require "test_helper"
require "webmock/minitest"

class Chat::GeminiTest < ActiveSupport::TestCase
  ENDPOINT = %r{\Ahttps://generativelanguage\.googleapis\.com/v1beta/models/gemini-2\.5-flash:generateContent}

  test "no API key: unavailable, and generate returns nil without making a request" do
    client = Chat::Gemini.new(api_key: nil)
    assert_not client.available?
    assert_nil client.generate(turns: [], tools: [], system_instruction: "x")
    assert_not_requested :post, ENDPOINT
  end

  test "with an API key: a 200 returns the candidate parts" do
    stub_request(:post, ENDPOINT).to_return(
      body: { candidates: [ { content: { parts: [ { text: "hi there" } ] } } ] }.to_json,
      headers: { "content-type" => "application/json" }
    )

    client = Chat::Gemini.new(api_key: "test-key")
    parts = client.generate(
      turns: [ { "role" => "user", "parts" => [ { "text" => "hi" } ] } ],
      tools: [], system_instruction: "be nice"
    )
    assert_equal [ { "text" => "hi there" } ], parts
    # The key authenticates via header and must never reach the query string:
    # URLs leak into access logs, proxies and exception messages.
    assert_requested(:post, ENDPOINT) do |req|
      req.headers["X-Goog-Api-Key"] == "test-key" && req.uri.query.nil?
    end
  end

  test "non-200 response degrades to nil instead of raising" do
    stub_request(:post, ENDPOINT).to_return(status: 429, body: '{"error":"rate limited"}')

    client = Chat::Gemini.new(api_key: "test-key")
    assert_nil client.generate(turns: [], tools: [], system_instruction: "x")
  end

  test "network failure degrades to nil instead of raising" do
    stub_request(:post, ENDPOINT).to_timeout

    client = Chat::Gemini.new(api_key: "test-key")
    assert_nil client.generate(turns: [], tools: [], system_instruction: "x")
  end
end
