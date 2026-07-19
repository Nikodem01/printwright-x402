require "test_helper"
require "webmock/minitest"

class Hedera::ExchangeRateTest < ActiveSupport::TestCase
  MIRROR = "https://testnet.mirrornode.hedera.com".freeze

  setup do
    @pin_was = ENV.delete("X402_DEMO_HBAR_PRICE_CENTS")
    Hedera::ExchangeRate.reset!
  end

  teardown do
    ENV["X402_DEMO_HBAR_PRICE_CENTS"] = @pin_was
    Hedera::ExchangeRate.reset!
  end

  test "env pin overrides the live rate" do
    ENV["X402_DEMO_HBAR_PRICE_CENTS"] = "25"
    assert_equal Rational(25), Hedera::ExchangeRate.cents_per_hbar
    assert_equal 100_000_000, Hedera::ExchangeRate.tinybars_for_cents(25) # 25c = 1 hbar
  end

  test "live rate comes from the mirror and is memoized for the TTL" do
    stub = stub_request(:get, "#{MIRROR}/api/v1/network/exchangerate")
      .to_return(body: { current_rate: { cent_equivalent: 201_278, hbar_equivalent: 30_000 } }.to_json,
                 headers: { "content-type" => "application/json" })

    rate = Hedera::ExchangeRate.cents_per_hbar
    assert_equal Rational(201_278, 30_000), rate
    # 25 cents at ~6.709c/hbar ~= 3.726 hbar
    assert_in_delta 3.726, Hedera::ExchangeRate.tinybars_for_cents(25) / 1e8, 0.01

    Hedera::ExchangeRate.cents_per_hbar
    assert_requested stub, times: 1
  end

  test "mirror failure serves the stale rate, or nil when never fetched" do
    stub_request(:get, "#{MIRROR}/api/v1/network/exchangerate").to_timeout
    assert_nil Hedera::ExchangeRate.cents_per_hbar
    assert_nil Hedera::ExchangeRate.tinybars_for_cents(25)

    Hedera::ExchangeRate.reset!
    stub_request(:get, "#{MIRROR}/api/v1/network/exchangerate")
      .to_return(body: { current_rate: { cent_equivalent: 200_000, hbar_equivalent: 30_000 } }.to_json,
                 headers: { "content-type" => "application/json" })
    assert_equal Rational(200_000, 30_000), Hedera::ExchangeRate.cents_per_hbar

    # rate held, mirror dies, TTL passes: the stale rate keeps being served
    stub_request(:get, "#{MIRROR}/api/v1/network/exchangerate").to_timeout
    travel_to 2.minutes.from_now do
      assert_equal Rational(200_000, 30_000), Hedera::ExchangeRate.cents_per_hbar
    end
  end

  test "mirror non-success response is treated as unavailable" do
    stub_request(:get, "#{MIRROR}/api/v1/network/exchangerate").to_return(status: 503)

    assert_nil Hedera::ExchangeRate.cents_per_hbar
  end
end
