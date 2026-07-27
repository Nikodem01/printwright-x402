require "test_helper"
require "omniauth"

# The OmniAuth request phase starts an account-linking flow, so a cross-site
# page must not be able to trigger it. Rodauth owns that check: rodauth-omniauth
# points OmniAuth's request_validation_phase at its own `check_csrf`, which
# rodauth-rails routes to Rails' verify_authenticity_token. A failed check is
# not an exception here — Rodauth redirects the request away without running
# the provider handshake.
#
# This pins the observable behavior, not the wiring, so it stays honest
# whichever gem supplies the verifier.
class OauthCsrfTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    OmniAuth.config.logger = Logger.new(IO::NULL)
    @forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
      provider: "github", uid: "gh-csrf", info: { email: "csrf@example.com", name: "CSRF Probe" }
    )
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @forgery_protection
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:github] = nil
  end

  test "a forged POST to the GitHub request phase is turned away and creates no account" do
    assert_no_difference -> { Designer.count } do
      post "/auth/github"
    end

    assert_redirected_to "/"
    assert_nil Designer.find_by(email_address: "csrf@example.com")

    # And the forged request left no session behind.
    get designer_account_path
    assert_not_equal 200, response.status, "a turned-away request must not authenticate a session"
  end

  test "the request phase refuses GET, so a plain cross-site link cannot start account linking" do
    assert_no_difference -> { Designer.count } do
      get "/auth/github"
      assert_not_equal 302, response.status,
        "a GET must not be accepted into the OmniAuth request phase"
    end
  end
end
