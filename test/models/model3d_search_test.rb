require "test_helper"
require "webmock/minitest"

class Model3dSearchTest < ActiveSupport::TestCase
  ENDPOINT = %r{\Ahttps://generativelanguage\.googleapis\.com/v1beta/models/gemini-embedding-001:embedContent}

  setup do
    @beaver = Model3d.create!(
      designer: designers(:one), title: "Articulated Beaver with Hat", slug: "b-#{SecureRandom.hex(3)}",
      tags: %w[beaver hat], status: "published"
    )
    Model3d.create!(designer: designers(:one), title: "Calibration Cube", slug: "c-#{SecureRandom.hex(3)}",
                    tags: %w[calibration], status: "published")
    @was_key = ENV["GOOGLE_GENERATIVE_AI_API_KEY"]
  end

  teardown { ENV["GOOGLE_GENERATIVE_AI_API_KEY"] = @was_key }

  test "misspelled query falls back to trigram similarity and finds the beaver" do
    assert_equal [ @beaver.id ], Model3d.search("beavr").pluck(:id)
    assert_equal [ @beaver.id ], Model3d.search("beever hat").pluck(:id)
  end

  test "exact matches still win and rank before fuzzy kicks in" do
    assert_equal @beaver.id, Model3d.search("beaver").first.id
  end

  test "linguistic matching finds car and cars without matching card or carabiner" do
    racer = Model3d.create!(
      designer: designers(:one), title: "Open-Wheel Racer", slug: "racer-#{SecureRandom.hex(3)}",
      description: "A compact open-wheel toy car.", tags: %w[race car], status: "published"
    )
    Model3d.create!(designer: designers(:one), title: "Business Card Rail", slug: "card-#{SecureRandom.hex(3)}",
                    description: "Display stand for cards.", tags: %w[business card], status: "published")
    Model3d.create!(designer: designers(:one), title: "Bag Hook", slug: "hook-#{SecureRandom.hex(3)}",
                    description: "A carabiner-style hook.", tags: %w[hook], status: "published")

    assert_equal [ racer.id ], Model3d.exact_search("car").pluck(:id)
    assert_equal [ racer.id ], Model3d.exact_search("cars").pluck(:id)
    assert_empty Model3d.exact_search("unrelated manufacturer")
  end

  test "garbage finds nothing" do
    assert_empty Model3d.search("zxqvw")
    assert_empty Model3d.search("")
  end

  test "without an API key, semantic_search is a no-op and search falls straight to fuzzy" do
    ENV["GOOGLE_GENERATIVE_AI_API_KEY"] = nil
    assert_empty Model3d.semantic_search("something to organize my desk cables")
    assert_not_requested :post, ENDPOINT
  end

  test "semantic pass finds a model with no exact/fuzzy overlap, when embeddings are close" do
    ENV["GOOGLE_GENERATIVE_AI_API_KEY"] = "test-key"
    organizer = Model3d.create!(
      designer: designers(:one), title: "Hexagon Desk Organizer", slug: "org-#{SecureRandom.hex(3)}",
      description: "Stackable hexagonal desk organizer cell.", tags: %w[organizer desk hexagon], status: "published"
    )
    vector = Array.new(768, 0.0)
    vector[3] = 1.0
    organizer.update_columns(embedding: vector)

    stub_request(:post, ENDPOINT)
      .to_return(body: JSON.generate(embedding: { values: vector }), headers: { "content-type" => "application/json" })

    # No word here appears in the organizer's title/description/tags, so
    # exact_search finds nothing and the semantic pass has to carry it.
    result = Model3d.search("gadget to keep my wires tidy")
    assert_equal [ organizer.id ], result.pluck(:id)
  end

  test "distance threshold excludes an off-topic query instead of returning the least-bad match" do
    ENV["GOOGLE_GENERATIVE_AI_API_KEY"] = "test-key"
    stored = Array.new(768, 0.0)
    stored[0] = 1.0
    @beaver.update_columns(embedding: stored)

    # Orthogonal to the stored vector: cosine distance 1.0, well past
    # SEMANTIC_DISTANCE_THRESHOLD (0.5) — nonsense should find nothing.
    query_vector = Array.new(768, 0.0)
    query_vector[1] = 1.0
    stub_request(:post, ENDPOINT)
      .to_return(body: JSON.generate(embedding: { values: query_vector }),
                 headers: { "content-type" => "application/json" })

    assert_empty Model3d.semantic_search("completely unrelated query")
  end

  test "query embeddings are cached briefly — a repeat search doesn't re-call the provider" do
    ENV["GOOGLE_GENERATIVE_AI_API_KEY"] = "test-key"
    vector = Array.new(768, 0.0)
    vector[5] = 1.0
    @beaver.update_columns(embedding: vector)
    stub_request(:post, ENDPOINT)
      .to_return(body: JSON.generate(embedding: { values: vector }), headers: { "content-type" => "application/json" })

    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    begin
      2.times { Model3d.semantic_search("repeat-me-nonsense-query") }
      assert_requested(:post, ENDPOINT, times: 1)
    ensure
      Rails.cache = original_cache
    end
  end
end
