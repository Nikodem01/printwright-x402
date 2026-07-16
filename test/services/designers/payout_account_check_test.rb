require "test_helper"
require "webmock/minitest"

# Semantics must match the facilitator's payTo preflight (@x402/hedera
# isPayToAssociated): direct USDC association, unlimited auto-association,
# or a free auto slot. Divergence = publish says yes, settle strands money.
class Designers::PayoutAccountCheckTest < ActiveSupport::TestCase
  MIRROR = "https://testnet.mirrornode.hedera.com".freeze
  ACCOUNT = "0.0.9604186".freeze

  test "directly USDC-associated account passes" do
    stub_tokens(tokens: [ { "token_id" => "0.0.429274" } ])
    assert Designers::PayoutAccountCheck.call(ACCOUNT)
  end

  test "unlimited auto-association passes without direct association" do
    stub_tokens(tokens: [])
    stub_account(max_auto: -1)
    assert Designers::PayoutAccountCheck.call(ACCOUNT)
  end

  test "zero auto-association slots and no association fails" do
    stub_tokens(tokens: [])
    stub_account(max_auto: 0)
    assert_not Designers::PayoutAccountCheck.call(ACCOUNT)
  end

  test "limited slots pass only while some remain free" do
    stub_tokens(tokens: [])
    stub_account(max_auto: 2)
    stub_request(:get, "#{MIRROR}/api/v1/accounts/#{ACCOUNT}/tokens")
      .to_return(body: { tokens: [ { "automatic_association" => true } ], links: {} }.to_json,
                 headers: { "content-type" => "application/json" })
    assert Designers::PayoutAccountCheck.call(ACCOUNT)

    stub_request(:get, "#{MIRROR}/api/v1/accounts/#{ACCOUNT}/tokens")
      .to_return(body: { tokens: [ { "automatic_association" => true }, { "automatic_association" => true } ], links: {} }.to_json,
                 headers: { "content-type" => "application/json" })
    assert_not Designers::PayoutAccountCheck.call(ACCOUNT)
  end

  test "missing account, malformed id, and mirror outage all fail closed" do
    assert_not Designers::PayoutAccountCheck.call(nil)
    assert_not Designers::PayoutAccountCheck.call("not-an-id")

    stub_tokens(tokens: [])
    stub_request(:get, "#{MIRROR}/api/v1/accounts/#{ACCOUNT}").to_return(status: 404)
    assert_not Designers::PayoutAccountCheck.call(ACCOUNT)

    stub_request(:get, "#{MIRROR}/api/v1/accounts/#{ACCOUNT}/tokens?token.id=0.0.429274").to_timeout
    assert_not Designers::PayoutAccountCheck.call(ACCOUNT)
  end

  private

  def stub_tokens(tokens:)
    stub_request(:get, "#{MIRROR}/api/v1/accounts/#{ACCOUNT}/tokens?token.id=0.0.429274")
      .to_return(body: { tokens: tokens }.to_json, headers: { "content-type" => "application/json" })
  end

  def stub_account(max_auto:)
    stub_request(:get, "#{MIRROR}/api/v1/accounts/#{ACCOUNT}")
      .to_return(body: { max_automatic_token_associations: max_auto }.to_json,
                 headers: { "content-type" => "application/json" })
  end
end
