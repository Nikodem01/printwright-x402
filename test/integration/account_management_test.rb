require "test_helper"

# Self-service account management (U1) + GDPR export/erasure (U2).
class AccountManagementTest < ActionDispatch::IntegrationTest
  test "account page renders profile, sessions, and security controls" do
    sign_in_as designers(:two)
    get designer_account_path
    assert_response :success
    assert_select "h1", text: "Account"
    assert_select "a[href=?]", "/change-password"
    assert_select "a[href=?]", export_designer_account_path
  end

  test "designer edits their profile" do
    sign_in_as designers(:two)
    patch designer_account_path, params: { designer: {
      display_name: "Renamed Studio", bio: "New bio", hedera_account_id: "0.0.777"
    } }
    assert_redirected_to designer_account_path
    designers(:two).reload.tap do |d|
      assert_equal "Renamed Studio", d.display_name
      assert_equal "New bio", d.bio
      assert_equal "0.0.777", d.hedera_account_id
    end
  end

  test "profile update rejects a blank display name" do
    sign_in_as designers(:two)
    patch designer_account_path, params: { designer: { display_name: "" } }
    assert_response :unprocessable_entity
    assert designers(:two).reload.display_name.present?
  end

  test "data export returns JSON without any credential material" do
    sign_in_as designers(:two)
    get export_designer_account_path
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal designers(:two).email_address, body.dig("account", "email_address")
    refute response.body.include?(designers(:two).password_digest)
    refute_match(/password_digest|otp|recovery/i, response.body)
  end

  test "sign out other devices keeps this session, drops the rest" do
    designer = designers(:two)
    designer.active_session_keys.create!(session_id: "another-device")
    sign_in_as designer
    assert_operator designer.active_session_keys.count, :>=, 2

    post revoke_other_sessions_designer_account_path
    assert_redirected_to designer_account_path
    assert_equal 1, designer.reload.active_session_keys.count
    refute designer.active_session_keys.exists?(session_id: "another-device")
  end

  test "closing an account anonymizes it and preserves the designer's models" do
    designer = designers(:two)
    model = designer.models3d.create!(title: "Keeps Living", slug: "keeps-living-#{SecureRandom.hex(3)}")
    sign_in_as designer

    post "/close-account", params: { password: "password" }

    designer.reload
    assert designer.account_closed?
    assert_equal "Closed account", designer.display_name
    assert_match(/\Aclosed-#{designer.id}@/, designer.email_address)
    assert Model3d.exists?(model.id), "buyers' models/licenses must survive account closure"
  end
end
