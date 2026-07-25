require "test_helper"
require "webmock/minitest"

class Designer::PayoutSetupControllerTest < ActionDispatch::IntegrationTest
  MIRROR = "https://testnet.mirrornode.hedera.com".freeze
  USDC = "0.0.429274".freeze

  setup do
    @designer = designers(:two)
    @designer.update!(hedera_account_id: nil, payout_account_verified_at: nil)
    sign_in_as @designer
  end

  teardown { RateLimitStore.backend = nil }

  test "the flow names the wallet step, the USDC step, and what happens to money meanwhile" do
    get designer_payout_setup_path

    assert_response :success
    assert_match "A wallet to be paid into", response.body
    assert_match "Let it receive USDC", response.body
    assert_match "Prove the wallet is yours", response.body
    # The non-crypto designer's actual question — a signature is not a transfer.
    assert_match(/does not authorize a transfer/, response.body)
    assert_select "a[href=?]", "https://www.hashpack.app/"
  end

  test "held earnings are stated, because setup is what releases them" do
    model = Model3d.create!(designer: @designer, title: "Owed", slug: "owed-#{SecureRandom.hex(4)}",
      status: "published", file_hash: "sha256:#{'a' * 64}")
    offer = model.license_offers.create!(kind: "personal", price_cents: 500)
    purchase = Purchase.create!(license_offer: offer, status: "settled",
      replay_key: SecureRandom.hex(32), payment_tx_id: "0.0.7@#{SecureRandom.hex(4)}")
    LedgerEntry.create!(purchase: purchase, designer: @designer, entry_kind: "designer_share",
      held_by: "treasury", asset: USDC, amount_base_units: 4_500_000)

    get designer_payout_setup_path

    assert_match "4.50 USDC", response.body
    assert_match(/held safely and pays out once this is done/, response.body)
  end

  test "checking a wallet that cannot receive USDC explains the fix instead of failing" do
    stub_request(:get, "#{MIRROR}/api/v1/accounts/0.0.7007/tokens?token.id=#{USDC}")
      .to_return(body: { tokens: [] }.to_json, headers: { "content-type" => "application/json" })
    stub_request(:get, "#{MIRROR}/api/v1/accounts/0.0.7007")
      .to_return(body: { max_automatic_token_associations: 0 }.to_json,
                 headers: { "content-type" => "application/json" })

    post designer_payout_setup_check_path, params: { account_id: "0.0.7007" },
      as: :turbo_stream

    assert_response :success
    assert_match "cannot receive USDC yet", response.body
    assert_match "Unlimited Auto Association", response.body
    # The fee question is the one that stops a designer with no HBAR.
    assert_match(/paid by whoever sends the tokens/, response.body)
  end

  test "a wallet that can receive USDC says so, and asks nothing further" do
    stub_request(:get, "#{MIRROR}/api/v1/accounts/0.0.7008/tokens?token.id=#{USDC}")
      .to_return(body: { tokens: [ { token_id: USDC } ] }.to_json,
                 headers: { "content-type" => "application/json" })

    post designer_payout_setup_check_path, params: { account_id: "0.0.7008" },
      as: :turbo_stream

    assert_response :success
    assert_match "can receive USDC", response.body
    assert_no_match(/Unlimited Auto Association/, response.body)
  end

  test "a staged wallet that cannot receive USDC is caught before the designer signs" do
    @designer.update!(payout_pending_account_id: "0.0.7009",
      payout_challenge: "challenge", payout_challenge_expires_at: 10.minutes.from_now,
      payout_change_requested_at: Time.current)
    stub_request(:get, "#{MIRROR}/api/v1/accounts/0.0.7009/tokens?token.id=#{USDC}")
      .to_return(body: { tokens: [] }.to_json, headers: { "content-type" => "application/json" })
    stub_request(:get, "#{MIRROR}/api/v1/accounts/0.0.7009")
      .to_return(body: { max_automatic_token_associations: 0 }.to_json,
                 headers: { "content-type" => "application/json" })

    get designer_payout_setup_path

    assert_response :success
    assert_match(/signing now would prove the wallet is yours and\s+still leave it unable to receive/,
      response.body)
  end

  test "an active destination reports done rather than repeating the setup" do
    # Two saves on purpose: changing the account id resets verification, which
    # is the app's rule and not something a fixture should bypass.
    @designer.update!(hedera_account_id: "0.0.7010")
    @designer.update!(payout_account_verified_at: Time.current,
      payout_account_control_verified_at: Time.current)

    # An active destination is settled business, so the page asks the mirror
    # nothing — an unstubbed request here would fail this test.
    get designer_payout_setup_path

    assert_response :success
    assert_match "Payouts go to", response.body
    assert_match "0.0.7010", response.body
  end

  test "the flow is designer-only" do
    sign_out
    get designer_payout_setup_path
    assert_response :redirect
  end
end
