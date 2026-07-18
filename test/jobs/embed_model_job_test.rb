require "test_helper"
require "webmock/minitest"

class EmbedModelJobTest < ActiveSupport::TestCase
  ENDPOINT = %r{\Ahttps://generativelanguage\.googleapis\.com/v1beta/models/gemini-embedding-001:embedContent}

  setup do
    @was_key = ENV["GOOGLE_GENERATIVE_AI_API_KEY"]
    ENV["GOOGLE_GENERATIVE_AI_API_KEY"] = "test-key"
    @model = Model3d.create!(
      designer: designers(:one), title: "Snap Cable Clip", slug: "clip-#{SecureRandom.hex(4)}",
      description: "Snap-fit cable clip.", tags: %w[cable clip], status: "published"
    )
  end

  teardown { ENV["GOOGLE_GENERATIVE_AI_API_KEY"] = @was_key }

  def stub_embedding(vector = Array.new(768) { 0.2 })
    stub_request(:post, ENDPOINT)
      .to_return(body: JSON.generate(embedding: { values: vector }), headers: { "content-type" => "application/json" })
  end

  test "embeds the model and stores the text digest" do
    stub_embedding
    EmbedModelJob.perform_now(@model.id)
    @model.reload
    assert_equal 768, @model.embedding.size
    assert_equal Digest::SHA256.hexdigest(@model.searchable_text), @model.embedding_text_digest
  end

  test "unchanged text is skipped (no request made)" do
    stub_embedding
    EmbedModelJob.perform_now(@model.id)
    @model.reload

    EmbedModelJob.perform_now(@model.id)
    assert_requested(:post, ENDPOINT, times: 1)
  end

  test "changed text re-embeds" do
    stub_embedding(Array.new(768) { 0.2 })
    EmbedModelJob.perform_now(@model.id)
    first_digest = @model.reload.embedding_text_digest

    @model.update_columns(description: "A completely different description.")
    stub_embedding(Array.new(768) { 0.3 })
    EmbedModelJob.perform_now(@model.id)

    assert_not_equal first_digest, @model.reload.embedding_text_digest
    assert_requested(:post, ENDPOINT, times: 2)
  end

  test "no API key: no-op, no request" do
    ENV["GOOGLE_GENERATIVE_AI_API_KEY"] = nil
    EmbedModelJob.perform_now(@model.id)
    assert_nil @model.reload.embedding
    assert_not_requested :post, ENDPOINT
  end

  test "provider failure leaves the model unembedded, not raised" do
    stub_request(:post, ENDPOINT).to_return(status: 500, body: "")
    EmbedModelJob.perform_now(@model.id)
    assert_nil @model.reload.embedding
  end

  test "deleted model is a no-op" do
    id = @model.id
    @model.destroy!
    assert_nothing_raised { EmbedModelJob.perform_now(id) }
    assert_not_requested :post, ENDPOINT
  end
end
