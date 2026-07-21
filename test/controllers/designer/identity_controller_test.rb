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
  end

  test "refuses a proof token missing from the profile" do
    profile_url = "https://www.printables.com/@missing-proof"
    post designer_identity_path, params: { profile_url: profile_url }
    verification = designers(:one).profile_verifications.last
    stub_request(:get, profile_url).to_return(body: "public profile without token")

    post verify_designer_identity_path, params: { verification_id: verification.id }

    assert_predicate verification.reload, :failed?
    assert_not designers(:one).reload.identity_verified?
  end

  test "pins verification to public DNS" do
    ProfileVerifications::Fetcher.resolver = ->(_host) { [ "127.0.0.1" ] }

    post designer_identity_path, params: { profile_url: "https://github.com/private" }

    assert_redirected_to designer_identity_path
    assert_empty designers(:one).profile_verifications
  end
end
