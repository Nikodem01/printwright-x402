require "test_helper"

class Designer::ModelsIndexTest < ActionDispatch::IntegrationTest
  setup do
    @designer = designers(:one)
    sign_in_as @designer
    @published = make_model("Cable Comb", status: "published")
    @draft = make_model("Draft Dragon", status: "draft")
    @paused = make_model("Paused Planter", status: "paused")
    @retired = make_model("Retired Rocket", status: "retired")
  end

  test "authentication is required" do
    sign_out
    get designer_models_path
    assert_redirected_to "/login"
  end

  test "lists all of this studio's models with a prominent add action and status counts" do
    get designer_models_path

    assert_response :success
    assert_select ".page-heading-row a.btn-primary[href=?]", new_designer_model_path, text: "Add model"
    assert_select ".catalog-tabs a", text: /All\s*4/
    assert_select ".catalog-tabs a", text: /Published\s*1/
    assert_select ".catalog-tabs a", text: /Draft\s*1/
    assert_select ".catalog-row", 4
  end

  test "status filter narrows to one visibility and marks the current tab" do
    get designer_models_path(status: "published")

    assert_response :success
    assert_select ".catalog-row", 1
    assert_select ".catalog-title", text: "Cable Comb"
    assert_select ".catalog-tabs a[aria-current='page']", text: /Published/
    assert_select ".catalog-title", { text: "Draft Dragon", count: 0 }
  end

  test "an unknown status falls back to all" do
    get designer_models_path(status: "nonsense")
    assert_response :success
    assert_select ".catalog-row", 4
  end

  test "title search is case-insensitive and escapes wildcards" do
    make_model("100% Cotton Clip", status: "published")

    get designer_models_path(q: "dragon")
    assert_select ".catalog-row", 1
    assert_select ".catalog-title", text: "Draft Dragon"

    # A literal % must not act as a wildcard matching every title.
    get designer_models_path(q: "100%")
    assert_select ".catalog-row", 1
    assert_select ".catalog-title", text: "100% Cotton Clip"
  end

  test "sort by title orders ascending" do
    get designer_models_path(sort: "title")
    titles = css_select(".catalog-title").map(&:text)
    assert_equal titles.sort, titles
  end

  test "draft rows show readiness progress; published rows do not" do
    get designer_models_path(status: "draft")
    assert_select ".catalog-meta", text: /required steps|Ready to publish/

    get designer_models_path(status: "published")
    assert_select ".catalog-meta", { text: /required steps/, count: 0 }
  end

  test "delivered sales count renders per model without buyer identity" do
    offer = @published.license_offers.create!(kind: "personal", price_cents: 250)
    purchase = Purchase.create!(license_offer: offer, status: "verified", buyer_hint: "0.0.777888",
      amount_base_units: "250000", asset: X402::Requirements.usdc_asset,
      replay_key: SecureRandom.hex(32), requirements_json: { "payTo" => ENV.fetch("X402_PAY_TO") })
    purchase.transition_to!(:settled)
    License.allocate!(purchase)
    purchase.transition_to!(:delivered)

    get designer_models_path

    assert_response :success
    assert_select ".catalog-side", text: /1 sold/
    refute_includes response.body, "0.0.777888"
  end

  test "never lists another studio's models" do
    designers(:two).models3d.create!(title: "Rival Widget", slug: "rival-widget-#{SecureRandom.hex(4)}",
      status: "published")

    get designer_models_path

    assert_response :success
    refute_includes response.body, "Rival Widget"
  end

  test "an empty studio shows the first-upload empty state" do
    @designer.models3d.destroy_all
    get designer_models_path
    assert_select ".empty-state", text: /No models yet/
    assert_select ".empty-state a.btn-primary", text: "Upload your first model"
  end

  test "a filter that matches nothing shows a contextual empty state, not the first-run one" do
    get designer_models_path(q: "zzzznomatch")
    assert_select ".empty-state", text: /No models match/
    assert_select ".empty-state", { text: /Upload your first model/, count: 0 }
  end

  private

  def make_model(title, status:)
    @designer.models3d.create!(title: title, slug: "#{title.parameterize}-#{SecureRandom.hex(4)}",
      status: status, file_hash: "sha256:#{SecureRandom.hex(32)}")
  end
end
