require "test_helper"

# The demo label is a safety claim, so its off-switch matters as much as its
# on-state: mainnet must silence it everywhere at once, or a future mainnet
# deployment would tell buyers their money is fake.
class X402::DemoNoticeTest < ActiveSupport::TestCase
  teardown { restore_printwright }

  test "active on testnet and carries the network, funds and a plain-language message" do
    set_printwright(hedera_network: "testnet")

    assert X402::DemoNotice.active?
    payload = X402::DemoNotice.payload
    assert_equal "testnet", payload[:network]
    assert_equal "test-only", payload[:funds]
    assert_match(/no monetary value/i, payload[:message])
  end

  test "header value names the environment, network and funds" do
    set_printwright(hedera_network: "testnet")

    assert_equal "demo; network=testnet; funds=test-only", X402::DemoNotice.header_value
  end

  test "silent on mainnet" do
    set_printwright(hedera_network: "mainnet")

    assert_not X402::DemoNotice.active?
  end
end
