require "test_helper"
require "webmock/minitest"
require "digest"

# Rodauth account hardening: password strength (S1), email verification gate (S2),
# per-account lockout (S4), and the legacy-digest login regression guard (Phase 0).
class AccountSecurityTest < ActionDispatch::IntegrationTest
  setup do
    # HIBP is consulted on every password create; default to "not breached".
    stub_request(:get, %r{api\.pwnedpasswords\.com/range/}).to_return(status: 200, body: "")
  end

  def create_account(email:, password:, display_name: "Studio", **extra)
    post "/create-account",
      params: { email: email, password: password, display_name: display_name, **extra }
  end

  test "signup rejects a short password" do
    assert_no_difference -> { Designer.count } do
      create_account(email: "short@example.com", password: "Ab1!xy")
    end
    assert_response :unprocessable_entity
  end

  test "signup rejects a weak (low-entropy) password" do
    assert_no_difference -> { Designer.count } do
      create_account(email: "weak@example.com", password: "password123")
    end
    assert_response :unprocessable_entity
  end

  test "signup rejects a breached password even when it is high-entropy" do
    password = "tangerine-dynamo-47-violet"
    sha1 = Digest::SHA1.hexdigest(password).upcase
    stub_request(:get, "https://api.pwnedpasswords.com/range/#{sha1[0, 5]}")
      .to_return(status: 200, body: "#{sha1[5..]}:9001")

    assert_no_difference -> { Designer.count } do
      create_account(email: "breached@example.com", password: password)
    end
    assert_response :unprocessable_entity
  end

  test "signup requires a display name" do
    assert_no_difference -> { Designer.count } do
      create_account(email: "nameless@example.com", password: "verdigris-kettle-9-monsoon", display_name: "")
    end
    assert_response :unprocessable_entity
  end

  test "signup with a strong password creates an unverified account" do
    assert_difference -> { Designer.count }, 1 do
      create_account(email: "fresh@example.com", password: "verdigris-kettle-9-monsoon")
    end
    designer = Designer.find_by!(email_address: "fresh@example.com")
    assert designer.account_unverified?
    refute designer.email_verified?
  end

  test "unverified designer cannot publish a model (S2)" do
    create_account(email: "pending@example.com", password: "verdigris-kettle-9-monsoon")
    designer = Designer.find_by!(email_address: "pending@example.com")
    model = designer.models3d.create!(title: "Draft", slug: "draft-#{SecureRandom.hex(3)}")

    post publish_designer_model_path(model), params: { warranty: "1" }
    assert_redirected_to edit_designer_model_path(model)
    assert_match(/verify your email/i, flash[:alert])
    refute model.reload.published?
  end

  test "account locks out after too many failed logins (S4)" do
    designer = designers(:two)
    11.times { post "/login", params: { email: designer.email_address, password: "wrong-password" } }

    # Even the correct password no longer authenticates once locked out.
    post "/login", params: { email: designer.email_address, password: "password" }
    get "/designer/models"
    assert_redirected_to "/login"
  end

  test "a legacy has_secure_password bcrypt digest still logs in (Phase 0 guard)" do
    Designer.create!(email_address: "legacy@example.com", display_name: "Legacy",
      status: "verified", password_digest: BCrypt::Password.create("HorseBatteryStaple99"))

    post "/login", params: { email: "legacy@example.com", password: "HorseBatteryStaple99" }
    assert_redirected_to "/designer/models"
  end
end
