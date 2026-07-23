require "test_helper"
require "webmock/minitest"

class Designer::IdentityControllerTest < ActionDispatch::IntegrationTest
  setup do
    @previous_resolver = ProfileVerifications::Fetcher.resolver
    ProfileVerifications::Fetcher.resolver = ->(_host) { [ "8.8.8.8" ] }
    sign_in_as designers(:one)
  end

  teardown do
    ProfileVerifications::Fetcher.resolver = @previous_resolver
  end

  test "signed public-bio challenge verifies identity end to end" do
    profile_url = "https://github.com/printwright-designer"
    post designer_identity_path, params: { profile_url: profile_url }
    verification = designers(:one).profile_verifications.last
    assert_redirected_to designer_identity_path
    assert verification.challenge_token.start_with?("printwright-proof:")
    stub_request(:get, profile_url).to_return(body: "<p>#{verification.challenge_token}</p>")

    post verify_designer_identity_path, params: { verification_id: verification.id }

    assert_redirected_to designer_identity_path
    assert_predicate verification.reload, :verified?
    assert_predicate designers(:one).reload, :identity_verified?
    assert_equal profile_url, designers(:one).verified_profile_url
    notification = designers(:one).seller_notifications.sole
    assert_equal "identity_verification_passed", notification.kind
    assert_equal({ "profile_url" => profile_url, "host" => "github.com" }, notification.payload)
  end

  test "refuses a proof token missing from the profile" do
    profile_url = "https://www.printables.com/@missing-proof"
    post designer_identity_path, params: { profile_url: profile_url }
    verification = designers(:one).profile_verifications.last
    stub_request(:get, profile_url).to_return(body: "public profile without token")

    post verify_designer_identity_path, params: { verification_id: verification.id }

    assert_predicate verification.reload, :failed?
    assert_not designers(:one).reload.identity_verified?
    notification = designers(:one).seller_notifications.sole
    assert_equal "identity_verification_failed", notification.kind
    assert_equal(
      { "profile_url" => profile_url, "host" => "www.printables.com",
        "reason" => "proof token is not visible in the public profile" },
      notification.payload
    )

    get designer_identity_path
    assert_select "[role='status']", text: /last check did not verify.*proof token is not visible/i
    assert_select "form[action=?]", verify_designer_identity_path do
      assert_select "button", text: "Check public profile again"
    end
  end

  test "pins verification to public DNS" do
    ProfileVerifications::Fetcher.resolver = ->(_host) { [ "127.0.0.1" ] }

    post designer_identity_path, params: { profile_url: "https://github.com/private" }

    assert_redirected_to designer_identity_path
    assert_empty designers(:one).profile_verifications
  end

  test "the page names supported hosts, badge placement, and token lifetime before submission" do
    get designer_identity_path

    assert_response :success
    assert_includes response.body, "GitHub, Printables, MakerWorld, Thingiverse, or Cults3D"
    assert_includes response.body, "every model page byline"
    assert_includes response.body, "expires after 2 days"
    assert_select "h2", text: "Start verification"
  end

  test "a pending challenge shows a copy control and an absolute UTC expiry" do
    post designer_identity_path, params: { profile_url: "https://github.com/copy-me" }
    verification = designers(:one).profile_verifications.last

    get designer_identity_path

    assert_select "[data-controller='clipboard']" do
      assert_select "[data-clipboard-target='source']", text: verification.challenge_token
      assert_select "button[aria-label='Copy proof token']"
    end
    assert_includes response.body, verification.expires_at.utc.strftime("%Y-%m-%d %H:%M UTC")
  end

  test "an expired challenge gets an honest expiry card instead of a dead check button" do
    post designer_identity_path, params: { profile_url: "https://github.com/too-late" }
    designers(:one).profile_verifications.last.update!(expires_at: 1.hour.ago)

    get designer_identity_path

    assert_select "[role='status']", text: /This challenge expired.*last 2 days/m
    assert_select "form[action=?]", verify_designer_identity_path, count: 0
  end

  test "success leads with the verified state, offers a different-profile path, and explains replacement" do
    profile_url = "https://github.com/printwright-designer"
    post designer_identity_path, params: { profile_url: profile_url }
    verification = designers(:one).profile_verifications.last
    stub_request(:get, profile_url).to_return(body: "<p>#{verification.challenge_token}</p>")
    post verify_designer_identity_path, params: { verification_id: verification.id }

    get designer_identity_path

    assert_select ".flash-ok .badge", text: /Identity verified/
    assert_select "h2", text: "Verify a different profile"
    assert_includes response.body, "stays active until then"
    assert_select "h2", { text: "Current challenge", count: 0 }
  end

  test "recent checks list bounded history with statuses, never another studio's rows" do
    3.times do |i|
      designers(:one).profile_verifications.create!(
        profile_url: "https://github.com/run-#{i}", host: "github.com",
        challenge_token: "printwright-proof:#{i}", expires_at: 2.days.from_now,
        status: i.zero? ? "failed" : "pending", last_error: i.zero? ? "proof token is not visible in the public profile" : nil
      )
    end
    designers(:two).profile_verifications.create!(
      profile_url: "https://github.com/other-studio", host: "github.com",
      challenge_token: "printwright-proof:other", expires_at: 2.days.from_now
    )

    get designer_identity_path

    assert_select "#identity-history-title", text: "Recent checks"
    assert_select "section[aria-labelledby='identity-history-title'] li", count: 2
    assert_includes response.body, "Failed — proof token is not visible"
    refute_includes response.body, "other-studio"
  end
end
