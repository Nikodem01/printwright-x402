require "test_helper"

class DesignersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @designer = Designer.create!(
      email_address: "profile@example.com", password: "s3curepass",
      display_name: "Profile Studio", bio: "We make desk gadgets.",
      hedera_account_id: "0.0.9604186", verified: true,
      identity_verified_at: Time.current, verified_profile_url: "https://github.com/profile-studio"
    )
    @published = Model3d.create!(
      designer: @designer, title: "Public Widget", slug: "public-widget",
      file_hash: "sha256:#{'a' * 64}", status: "published"
    )
    @published.license_offers.create!(kind: "personal", price_cents: 150, terms_md: "T.")
    Model3d.create!(designer: @designer, title: "Draft Widget", slug: "draft-widget", status: "draft")
  end

  test "public profile shows display name, labeled verification, bio, and published models — never the payout account id" do
    get designer_path(@designer)
    assert_response :success
    assert_select "h1", text: /Profile Studio/
    assert_select "h1 .badge", text: /Identity verified/
    assert_select ".prose", text: /desk gadgets/
    refute_match "0.0.9604186", response.body
    assert_select ".model-card", 1
    assert_select ".model-card h3", text: "Public Widget"
    assert_select ".model-card", { text: /Draft Widget/, count: 0 }
  end

  test "a verified payout destination appears only as a platform state, never as the account id" do
    @designer.update!(payout_account_verified_at: Time.current)

    get designer_path(@designer)

    assert_response :success
    assert_includes response.body, "Verified Hedera payout destination"
    refute_match "0.0.9604186", response.body
  end

  test "optional trust fields render only when present, links as nofollow host labels" do
    get designer_path(@designer)
    refute_includes response.body, "rel=\"nofollow noopener ugc\""

    @designer.update!(specialty: "Print-in-place mechanisms", location: "Adelaide, Australia",
      profile_links: [ "https://www.printables.com/@profile-studio" ])

    get designer_path(@designer)

    assert_response :success
    assert_includes response.body, "Print-in-place mechanisms"
    assert_includes response.body, "Adelaide, Australia"
    assert_select "a[rel='nofollow noopener ugc'][href='https://www.printables.com/@profile-studio']",
      text: "printables.com"
  end

  test "the featured model is pinned first and falls back when it leaves publication" do
    second = Model3d.create!(
      designer: @designer, title: "Second Widget", slug: "second-widget",
      file_hash: "sha256:#{'b' * 64}", status: "published"
    )
    second.license_offers.create!(kind: "personal", price_cents: 100, terms_md: "T.")
    @designer.update!(featured_model_id: second.id)

    get designer_path(@designer)
    assert_select "h2", text: "Featured"
    featured_grid = css_select(".card-grid").first
    assert_includes featured_grid.text, "Second Widget"
    refute_includes featured_grid.text, "Public Widget"

    second.update!(status: "paused")
    get designer_path(@designer)
    assert_select "h2", { text: "Featured", count: 0 }
    assert_select ".model-card", 1
  end

  test "public profile never renders the designer's email or password digest" do
    get designer_path(@designer)
    assert_response :success
    refute_match @designer.email_address, response.body
    refute_match @designer.password_digest, response.body
  end

  test "public profile enqueues only aggregate impressions for published models" do
    clear_enqueued_jobs

    perform_enqueued_jobs(only: RecordModelMetricsJob) { get designer_path(@designer) }

    assert_response :success
    metric = @published.model_metrics.find_by!(channel: "human", source: "profile")
    assert_equal 1, metric.impressions
    assert_equal 0, Model3d.find_by!(slug: "draft-widget").model_metrics.count
  end

  test "unverified designer gets no checkmark" do
    @designer.update!(verified: false, identity_verified_at: nil, verified_profile_url: nil)
    get designer_path(@designer)
    assert_select "h1", text: /Profile Studio/
    assert_select "h1", { text: /✓/, count: 0 }
  end

  test "designer with no published models shows an honest empty state" do
    @published.update!(status: "draft")
    get designer_path(@designer)
    assert_response :success
    assert_select ".empty-state"
    assert_select ".model-card", 0
  end

  test "unknown designer id 404s" do
    get designer_path(id: 999_999)
    assert_response :not_found
  end
end
