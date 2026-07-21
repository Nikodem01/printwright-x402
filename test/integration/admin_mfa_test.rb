require "test_helper"

# Operator MFA + money-path reauth (S3).
class AdminMfaTest < ActionDispatch::IntegrationTest
  test "an admin without 2FA is bounced to enrollment before any operator screen" do
    # Log in directly (bypassing the helper that auto-enrolls) so no 2FA exists.
    post "/login", params: { email: designers(:one).email_address, password: "password" }

    get admin_root_path
    assert_response :redirect
    # Bounced to a two-factor setup route, not into the operator panel.
    assert_match(%r{/(otp-setup|multifactor-manage|two-factor)}, URI(response.location).path)
  end

  test "a non-admin is forbidden, never asked to set up 2FA" do
    sign_in_as designers(:two)
    get admin_root_path
    assert_response :forbidden
  end

  test "running a payout after the password grace lapses forces reauth (S3)" do
    admin = designers(:one)
    sign_in_as admin # enrolls 2FA; password grace active from login

    travel 6.minutes do
      post run_admin_payout_path, params: { confirm: "1" }
      assert_response :redirect
      assert_match %r{/confirm-password}, URI(response.location).path
    end
  end

  test "a payout within the grace window is not interrupted by reauth" do
    admin = designers(:one)
    sign_in_as admin

    # No hedera payout wired, but the request reaches the action (refused for
    # missing confirmation) rather than being redirected to confirm-password.
    post run_admin_payout_path
    assert_redirected_to admin_root_path
    assert_equal "payout_refused", AdminAuditLog.order(:id).last.action
  end
end
