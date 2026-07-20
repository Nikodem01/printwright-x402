require "test_helper"

class StorefrontControllerTest < ActionDispatch::IntegrationTest
  setup do
    @beaver = Model3d.create!(
      designer: designers(:one), title: "Articulated Beaver with Hat", slug: "beaver-with-hat",
      tags: %w[beaver hat], description: "A cheerful beaver.",
      category: "toys-and-games", collections: %w[support-free-essentials],
      printability: { "supports" => false, "materials" => %w[PLA], "est_print_minutes" => 95 },
      file_hash: "sha256:#{'a' * 64}", status: "published"
    )
    @beaver.license_offers.create!(kind: "personal", price_cents: 250, terms_md: "T.")
    Model3d.create!(designer: designers(:one), title: "Hidden Draft", slug: "hidden-draft", status: "draft")
  end

  test "browse lists published models with price and printability facts" do
    get root_path
    assert_response :success
    assert_select "section#models"
    assert_select "form.search-form[action=?]", root_path(anchor: "models")
    assert_select ".model-card", 1
    assert_select ".model-card h3", text: "Articulated Beaver with Hat"
    assert_select ".price", text: "2.50 USDC"
    assert_select ".model-card", { text: /Hidden Draft/, count: 0 }
  end

  test "search narrows and empty search shows the empty state" do
    get root_path(q: "beaver")
    assert_select ".model-card", 1
    get root_path(q: "zeppelin")
    assert_select ".empty-state"
  end

  test "active filter pills expose their current state" do
    get root_path(supports_free: "1")
    assert_select '.pill[aria-current="true"]', text: "Support-free"
    assert_select '.pill[href$="#models"]', minimum: 3
  end

  test "category pages expose curated taxonomy and only matching models" do
    organizer = Model3d.create!(
      designer: designers(:one), title: "Pen Tray", slug: "pen-tray", status: "published",
      category: "desk-organization", collections: %w[support-free-essentials small-space]
    )
    organizer.license_offers.create!(kind: "personal", price_cents: 150)

    get category_path("desk-organization")

    assert_response :success
    assert_select "h1", text: "Desk organization"
    assert_select ".model-card", text: /Pen Tray/, count: 1
    assert_select ".model-card", text: /Beaver/, count: 0
    assert_select '.browse-card[aria-current="page"]', text: /Desk organization/
    assert_select '.browse-card[href$="#models"]'
  end

  test "collection pages filter across categories" do
    organizer = Model3d.create!(
      designer: designers(:one), title: "Pen Tray", slug: "pen-tray", status: "published",
      category: "desk-organization", collections: %w[support-free-essentials small-space]
    )
    organizer.license_offers.create!(kind: "personal", price_cents: 150)

    get collection_path("small-space")

    assert_response :success
    assert_select "h1", text: "Small-space wins"
    assert_select ".model-card", text: /Pen Tray/, count: 1
    assert_select ".model-card", text: /Beaver/, count: 0
  end

  test "unknown catalog taxonomy 404s" do
    get category_path("not-a-category")
    assert_response :not_found

    get collection_path("not-a-collection")
    assert_response :not_found
  end

  test "model page renders buy panel, trust strip, and JSON-LD print licenses" do
    hostile_description = "Useful clip </script><script>alert('markup injection')</script>"
    @beaver.update!(description: hostile_description)
    get model_page_path(@beaver.slug)
    assert_response :success
    refute_includes response.body, hostile_description
    assert_select "h1", text: @beaver.title
    assert_select ".buy-panel .offer-row", 1
    assert_select ".trust-strip .mono", text: /sha256:/
    assert_select ".trust-strip", text: /Public integrity check/
    assert_select ".copy-btn", text: "copy full hash"
    assert_select 'script[type="application/ld+json"]' do |nodes|
      product = JSON.parse(nodes.first.text)
      assert_equal "Product", product["@type"]
      assert_equal hostile_description, product["description"]
      assert_equal "2.50", product["offers"].first["price"]
      assert_equal "USDC", product["offers"].first["priceCurrency"]
      license = product["offers"].first.fetch("itemOffered")
      assert_equal "DigitalDocument", license["@type"]
      assert_equal "PrintLicense", license["additionalType"]
      assert_equal "Personal print license", license["name"]
      assert_includes product["offers"].first["url"], "/download?license=personal"
    end
  end

  test "capped offer reports license slots without claiming physical scarcity" do
    offer = @beaver.license_offers.sole
    offer.update!(max_units: 3)
    Purchase.create!(license_offer: offer, status: "pending", replay_key: SecureRandom.hex(32))

    get model_page_path(@beaver.slug)

    assert_select ".offer-row", text: /2 of 3 license slots available/
    assert_select ".buy-panel", text: /not a claim of physical scarcity/
    assert_select ".buy-panel", text: /does not technically prevent/
  end

  test "commercial offers expose a quantity bounded by batch size and remaining slots" do
    @beaver.license_offers.create!(kind: "commercial_unit", price_cents: 60, max_units: 7)

    get model_page_path(@beaver.slug)

    assert_select "[data-checkout-batch-url-value='#{api_v1_batches_path}']"
    assert_select "input[aria-label='Commercial units'][min='1'][max='7'][value='1']", 1
    assert_select ".license-quantity", text: /0.60 USDC each/
  end

  test "model page exposes rendered turntable frames without the printable mesh" do
    source = @beaver.model_files.create!(kind: "stl", position: 0)
    source.file.attach(io: Rails.root.join("db/seed_assets/beaver-with-hat.stl").open,
                       filename: "beaver.stl", content_type: "model/stl")
    render = @beaver.model_files.create!(kind: "render", position: 1)
    render.file.attach(io: Rails.root.join("db/seed_assets/beaver-with-hat.png").open,
                       filename: "beaver.png", content_type: "image/png")
    PreviewMeshes::Attacher.call(@beaver)

    get model_page_path(@beaver.slug)

    assert_select "[data-controller='render-turntable'][data-render-turntable-frames-value]"
    assert_select "[data-render-turntable-target='image']"
    refute_includes response.body, source.file.filename.to_s
  end

  test "draft model pages 404" do
    get model_page_path("hidden-draft")
    assert_response :not_found
  end

  test "landing page narrates the three doors and how a purchase works" do
    get root_path
    assert_response :success
    assert_select "h2", text: "Shop with AI"
    assert_select "h2", text: "Humans"
    assert_select "h2", text: /Agents & print servers/i
    assert_select ".hero-shopkeeper form[action=?]", chat_path
    assert_select ".hero-chat-messages[data-controller='chat-scroll']"
    assert_select "a[href=?]", docs_path
  end

  test "landing shopkeeper retains the complete stored conversation" do
    get chat_path
    conversation = ChatConversation.find(session[:chat_conversation_id])
    conversation.update!(turns: [
      { "role" => "user", "parts" => [ { "text" => "old question" } ] },
      { "role" => "model", "parts" => [ { "text" => "old answer" } ] },
      { "role" => "user", "parts" => [ { "text" => "latest question" } ] },
      { "role" => "model", "parts" => [ { "text" => "latest answer" } ] }
    ])

    get root_path

    assert_select ".hero-chat-messages", text: /old question.*old answer.*latest question.*latest answer/
  end
end
