require "test_helper"
require "webmock/minitest"

class Designer::PayoutDestinationsControllerTest < ActionDispatch::IntegrationTest
  SIDECAR = "http://localhost:4021".freeze
  MIRROR = "https://testnet.mirrornode.hedera.com".freeze

  setup do
    ENV["SIDECAR_TOKEN"] = "test-token"
    @designer = designers(:two)
    @designer.update!(hedera_account_id: nil, payout_account_verified_at: nil)
    clear_enqueued_jobs
    sign_in_as @designer
  end

  teardown { RateLimitStore.backend = nil }

  test "payout settings require enrolled two-factor authentication" do
    post designer_payout_destination_path, params: { account_id: "0.0.7007" }

    assert_redirected_to "/multifactor-manage"
    assert_not @designer.reload.payout_destination_change_pending?
  end

  test "staging requires recent password authentication even after two-factor enrollment" do
    complete_two_factor_setup("password")

    travel 6.minutes do
      post designer_payout_destination_path, params: { account_id: "0.0.7007" }
      assert_redirected_to "/confirm-password"
      post "/confirm-password", params: { password: "password" }
      assert_redirected_to designer_payouts_path(anchor: "payout-destination")
    end
    assert_not @designer.reload.payout_destination_change_pending?
  end

  test "designer stages, proves, and activates a first destination from Payouts" do
    complete_two_factor_setup("password")
    post designer_payout_destination_path, params: { account_id: "0.0.7007" }

    assert_redirected_to designer_payouts_path(anchor: "payout-destination")
    message = @designer.reload.payout_challenge
    assert message.present?

    stub_request(:post, "#{SIDECAR}/verify-payout-proof")
      .with(headers: { "Authorization" => "Bearer test-token" },
            body: hash_including("accountId" => "0.0.7007", "message" => message,
              "signatureMap" => "signed-map"))
      .to_return(body: { verified: true }.to_json,
                 headers: { "content-type" => "application/json" })
    stub_request(:get, "#{MIRROR}/api/v1/accounts/0.0.7007/tokens?token.id=0.0.429274")
      .to_return(body: { tokens: [ { token_id: "0.0.429274" } ] }.to_json,
                 headers: { "content-type" => "application/json" })

    post verify_designer_payout_destination_path,
      params: { message: message, signature_map: "signed-map" }

    assert_redirected_to designer_payouts_path(anchor: "payout-destination")
    assert_equal "0.0.7007", @designer.reload.hedera_account_id
    assert @designer.payout_account_verified?
    assert @designer.payout_account_control_verified_at.present?
    assert_enqueued_emails 2
  end

  test "failed proof leaves the active destination and payout eligibility unchanged" do
    @designer.update!(hedera_account_id: "0.0.6006")
    @designer.update!(payout_account_verified_at: Time.current,
      payout_account_control_verified_at: Time.current)
    complete_two_factor_setup("password")
    post designer_payout_destination_path, params: { account_id: "0.0.7007" }
    message = @designer.reload.payout_challenge
    stub_request(:post, "#{SIDECAR}/verify-payout-proof")
      .to_return(body: { verified: false }.to_json,
                 headers: { "content-type" => "application/json" })

    post verify_designer_payout_destination_path,
      params: { message: message, signature_map: "wrong-map" }

    assert_redirected_to designer_payouts_path(anchor: "payout-destination")
    assert_equal "0.0.6006", @designer.reload.hedera_account_id
    assert @designer.payout_account_verified?
    assert_equal :awaiting_proof, @designer.payout_destination_state
  end
end
