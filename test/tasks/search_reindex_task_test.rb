require "test_helper"
require "webmock/minitest"
require "rake"

class SearchReindexTaskTest < ActiveSupport::TestCase
  ENDPOINT = %r{\Ahttps://generativelanguage\.googleapis\.com/v1beta/models/gemini-embedding-001:embedContent}

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("search:reindex")
    Rake::Task["search:reindex"].reenable
    @was_key = ENV["GOOGLE_GENERATIVE_AI_API_KEY"]
    @model = Model3d.create!(
      designer: designers(:one), title: "Reindex Me", slug: "ri-#{SecureRandom.hex(4)}",
      description: "A model for the reindex task test.", tags: %w[reindex]
    )
  end

  teardown do
    ENV["GOOGLE_GENERATIVE_AI_API_KEY"] = @was_key
    ENV.delete("FORCE")
  end

  def run_task
    Rake::Task["search:reindex"].invoke
  ensure
    Rake::Task["search:reindex"].reenable
  end

  test "no API key: no-op, no request" do
    ENV["GOOGLE_GENERATIVE_AI_API_KEY"] = nil
    run_task
    assert_nil @model.reload.embedding
    assert_not_requested :post, ENDPOINT
  end

  test "embeds the catalog, then skips unchanged models on a re-run (idempotent)" do
    ENV["GOOGLE_GENERATIVE_AI_API_KEY"] = "test-key"
    vector = Array.new(768) { 0.4 }
    stub_request(:post, ENDPOINT)
      .to_return(body: JSON.generate(embedding: { values: vector }), headers: { "content-type" => "application/json" })

    run_task
    assert_equal vector, @model.reload.embedding
    assert_requested(:post, ENDPOINT, times: 1)

    run_task # nothing changed -- must not re-call the provider
    assert_requested(:post, ENDPOINT, times: 1)
  end

  test "FORCE=1 re-embeds even when the text hasn't changed" do
    ENV["GOOGLE_GENERATIVE_AI_API_KEY"] = "test-key"
    vector = Array.new(768) { 0.4 }
    stub_request(:post, ENDPOINT)
      .to_return(body: JSON.generate(embedding: { values: vector }), headers: { "content-type" => "application/json" })

    run_task
    ENV["FORCE"] = "1"
    run_task
    assert_requested(:post, ENDPOINT, times: 2)
  end
end
