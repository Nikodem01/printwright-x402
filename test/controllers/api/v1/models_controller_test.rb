require "test_helper"

class Api::V1::ModelsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @designer = designers(:one)
    @beaver = create_model!(
      title: "Articulated Beaver with Hat", slug: "beaver-with-hat",
      tags: %w[beaver hat animal], description: "A cheerful beaver.",
      printability: { "supports" => false, "materials" => %w[PLA PETG], "est_print_minutes" => 95 },
      offers: [ { kind: "personal", price_cents: 250 }, { kind: "commercial_unit", price_cents: 60 } ]
    )
    # Title doesn't match "beaver", tag does — must rank below the title match.
    @lodge = create_model!(
      title: "Woodland Lodge Kit", slug: "woodland-lodge",
      tags: %w[beaver lodge diorama], description: "Build a lodge.",
      printability: { "supports" => true, "materials" => %w[PLA] },
      offers: [ { kind: "personal", price_cents: 900 } ]
    )
    @cube = create_model!(
      title: "Calibration Cube", slug: "calibration-cube",
      tags: %w[calibration test], description: "20mm cube.",
      printability: { "supports" => false, "materials" => %w[ABS] },
      offers: [ { kind: "personal", price_cents: 120 } ]
    )
    create_model!(title: "Secret Draft", slug: "secret-draft", status: "draft",
                  tags: %w[beaver], offers: [ { kind: "personal", price_cents: 100 } ])
  end

  test "index lists only published models in the specced shape" do
    get api_v1_models_url
    assert_response :success
    body = response.parsed_body
    assert_equal 3, body["count"]
    model = body["models"].find { |m| m["slug"] == "beaver-with-hat" }
    assert_equal "Articulated Beaver with Hat", model["title"]
    assert_equal({ "name" => @designer.display_name }, model["designer"])
    assert_equal false, model["printability"]["supports"]
    assert_equal [ %w[personal 250 USDC], %w[commercial_unit 60 USDC] ].map { |k, p, c| { "kind" => k, "price_cents" => p.to_i, "currency" => c } },
                 model["license_offers"]
    assert_includes model["url"], "/api/v1/models/#{@beaver.id}"
  end

  test "q=beaver ranks the title match first and excludes drafts" do
    get api_v1_models_url(q: "beaver")
    body = response.parsed_body
    assert_equal %w[beaver-with-hat woodland-lodge], body["models"].map { |m| m["slug"] }
  end

  test "multi-word query requires every term and ranks the double title hit first" do
    get api_v1_models_url(q: "beaver hat")
    assert_equal %w[beaver-with-hat], response.parsed_body["models"].map { |m| m["slug"] }
  end

  test "material filter matches inside printability jsonb" do
    get api_v1_models_url(material: "ABS")
    assert_equal %w[calibration-cube], response.parsed_body["models"].map { |m| m["slug"] }
  end

  test "supports filter" do
    get api_v1_models_url(supports: "true")
    assert_equal %w[woodland-lodge], response.parsed_body["models"].map { |m| m["slug"] }
  end

  test "max_price_cents keeps models with at least one affordable offer" do
    get api_v1_models_url(max_price_cents: 150)
    assert_equal %w[beaver-with-hat calibration-cube].sort,
                 response.parsed_body["models"].map { |m| m["slug"] }.sort
  end

  test "search and max_price filter combine (regression: DISTINCT vs ranked ORDER BY)" do
    get api_v1_models_url(q: "beaver", max_price_cents: 300)
    assert_response :success
    assert_equal %w[beaver-with-hat], response.parsed_body["models"].map { |m| m["slug"] }
  end

  test "show returns full metadata" do
    get api_v1_model_url(@beaver)
    assert_response :success
    body = response.parsed_body
    assert_equal @beaver.file_hash, body["file_hash"]
    assert_equal %w[beaver hat animal], body["tags"]
    assert body["license_offers"].all? { |o| o.key?("terms") && o.key?("max_units") }
    assert_includes body["download_url"], "/download?license={kind}"
    assert_equal @designer.display_name, body.dig("designer", "name")
  end

  test "show 404s for drafts and unknown ids" do
    draft = Model3d.find_by(slug: "secret-draft")
    get api_v1_model_url(draft)
    assert_response :not_found
    get api_v1_model_url(id: 999_999)
    assert_response :not_found
    assert_equal({ "error" => "not_found" }, response.parsed_body)
  end

  private

  def create_model!(title:, slug:, offers:, tags: [], description: nil, printability: {}, status: "published")
    model = Model3d.create!(
      designer: @designer, title: title, slug: slug, tags: tags,
      description: description, printability: printability,
      file_hash: "sha256:#{Digest::SHA256.hexdigest(slug)}", status: status
    )
    offers.each { |o| model.license_offers.create!(currency: "USDC", terms_md: "Terms.", **o) }
    model
  end
end
