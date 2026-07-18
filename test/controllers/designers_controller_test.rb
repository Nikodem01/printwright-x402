require "test_helper"

class DesignersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @designer = Designer.create!(
      email_address: "profile@example.com", password: "s3curepass",
      display_name: "Profile Studio", bio: "We make desk gadgets.",
      hedera_account_id: "0.0.9604186", verified: true
    )
    @published = Model3d.create!(
      designer: @designer, title: "Public Widget", slug: "public-widget",
      file_hash: "sha256:#{'a' * 64}", status: "published"
    )
    @published.license_offers.create!(kind: "personal", price_cents: 150, terms_md: "T.")
    Model3d.create!(designer: @designer, title: "Draft Widget", slug: "draft-widget", status: "draft")
  end

  test "public profile shows display name, verified badge, bio, payout account, and published models only" do
    get designer_path(@designer)
    assert_response :success
    assert_select "h1", text: /Profile Studio/
    assert_select "h1", text: /✓/
    assert_select ".prose", text: /desk gadgets/
    assert_select ".mono", text: "0.0.9604186"
    assert_select ".model-card", 1
    assert_select ".model-card h3", text: "Public Widget"
    assert_select ".model-card", { text: /Draft Widget/, count: 0 }
  end

  test "public profile never renders the designer's email or password digest" do
    get designer_path(@designer)
    assert_response :success
    refute_match @designer.email_address, response.body
    refute_match @designer.password_digest, response.body
  end

  test "unverified designer gets no checkmark" do
    @designer.update!(verified: false)
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
