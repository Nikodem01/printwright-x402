require "test_helper"
require "webmock/minitest"

class Search::EmbedderTest < ActiveSupport::TestCase
  ENDPOINT = %r{\Ahttps://generativelanguage\.googleapis\.com/v1beta/models/gemini-embedding-001:embedContent}

  test "no API key: unavailable, and embed returns nil without making a request" do
    embedder = Search::Embedder.new(api_key: nil)
    assert_not embedder.available?
    assert_nil embedder.embed("cable clip")
    assert_not_requested :post, ENDPOINT
  end

  test "with an API key: available, and a 200 returns the embedding values" do
    vector = Array.new(768) { 0.1 }
    stub_request(:post, ENDPOINT)
      .to_return(body: JSON.generate(embedding: { values: vector }), headers: { "content-type" => "application/json" })

    embedder = Search::Embedder.new(api_key: "test-key")
    assert embedder.available?
    assert_equal vector, embedder.embed("cable clip")
    assert_requested(:post, ENDPOINT) { |req| req.uri.query == "key=test-key" }
  end

  test "non-200 response degrades to nil instead of raising" do
    stub_request(:post, ENDPOINT).to_return(status: 429, body: '{"error":"rate limited"}')

    embedder = Search::Embedder.new(api_key: "test-key")
    assert_nil embedder.embed("cable clip")
  end

  test "network failure degrades to nil instead of raising" do
    stub_request(:post, ENDPOINT).to_timeout

    embedder = Search::Embedder.new(api_key: "test-key")
    assert_nil embedder.embed("cable clip")
  end

  test "blank text never makes a request" do
    embedder = Search::Embedder.new(api_key: "test-key")
    assert_nil embedder.embed("")
    assert_not_requested :post, ENDPOINT
  end
end
