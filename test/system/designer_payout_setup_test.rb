require "application_system_test_case"
require "webmock/minitest"

# The guided payout flow, driven as a designer with no crypto background: the
# question it has to answer in the browser is "can this wallet actually be paid
# yet", and it has to answer it before they sign anything.
class DesignerPayoutSetupTest < RackSystemTestCase
  MIRROR = "https://testnet.mirrornode.hedera.com".freeze
  USDC = "0.0.429274".freeze

  setup { WebMock.disable_net_connect!(allow_localhost: true) }

  test "the checklist leads to the flow, and checking a wallet answers in place" do
    designer = designers(:two)
    designer.update!(hedera_account_id: nil, payout_account_verified_at: nil)

    visit "/login"
    fill_in "email", with: designer.email_address
    fill_in "password", with: "password"
    click_on "Login"

    # The dashboard item is the entry point — an unfinished payout step now
    # names its own action instead of just reporting "To do".
    click_on "Set up payouts"
    assert_current_path designer_payout_setup_path
    assert_text "Get paid"
    assert_text "Let it receive USDC"

    # A fresh HashPack wallet: no USDC association, no auto-association slots.
    stub_request(:get, "#{MIRROR}/api/v1/accounts/0.0.7007/tokens?token.id=#{USDC}")
      .to_return(body: { tokens: [] }.to_json, headers: { "content-type" => "application/json" })
    stub_request(:get, "#{MIRROR}/api/v1/accounts/0.0.7007")
      .to_return(body: { max_automatic_token_associations: 0 }.to_json,
                 headers: { "content-type" => "application/json" })

    fill_in "Your Hedera account id", with: "0.0.7007"
    click_on "Check my wallet"

    assert_text "cannot receive USDC yet"
    assert_text "Unlimited Auto Association"

    # They flip the toggle in HashPack and ask again — same page, new answer.
    remove_request_stub(
      stub_request(:get, "#{MIRROR}/api/v1/accounts/0.0.7007/tokens?token.id=#{USDC}")
    )
    stub_request(:get, "#{MIRROR}/api/v1/accounts/0.0.7007/tokens?token.id=#{USDC}")
      .to_return(body: { tokens: [ { token_id: USDC } ] }.to_json,
                 headers: { "content-type" => "application/json" })

    fill_in "Your Hedera account id", with: "0.0.7007"
    click_on "Check my wallet"

    assert_text "can receive USDC"
    assert_no_text "cannot receive USDC yet"
  end
end
