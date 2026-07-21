require "test_helper"
require "omniauth"

# Social login (U3): GitHub/Google via rodauth-omniauth, linking by verified email.
class OauthLoginTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    OmniAuth.config.logger = Logger.new(IO::NULL)
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:github] = nil
  end

  def mock_github(email:, uid: "gh-#{SecureRandom.hex(4)}", name: "GitHub User")
    OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
      provider: "github", uid: uid, info: { email: email, name: name }
    )
  end

  def authenticate_via_github
    post "/auth/github"
    follow_redirect! # -> /auth/github/callback, handled by Rodauth
  end

  test "a first-time GitHub user gets a verified account and is signed in" do
    mock_github(email: "newcomer@example.com", name: "New Comer")

    assert_difference -> { Designer.count }, 1 do
      authenticate_via_github
    end

    designer = Designer.find_by!(email_address: "newcomer@example.com")
    assert designer.account_verified?, "provider-verified email should not need our verification"
    assert_equal "New Comer", designer.display_name

    get designer_account_path
    assert_response :success # session is authenticated
  end

  test "GitHub login links to an existing account by email instead of duplicating" do
    existing = designers(:two)
    mock_github(email: existing.email_address)

    assert_no_difference -> { Designer.count } do
      authenticate_via_github
    end

    assert_equal 1, existing.reload.identities.count
    assert_equal "github", existing.identities.first.provider
  end
end
