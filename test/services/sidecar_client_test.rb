require "test_helper"
require "webmock/minitest"

class SidecarClientTest < ActiveSupport::TestCase
  SIDECAR = "http://localhost:4021".freeze

  setup { ENV["SIDECAR_TOKEN"] = "test-token" }

  test "payout treats a sidecar Hedera error as an ambiguous transfer result" do
    stub_request(:post, "#{SIDECAR}/payout")
      .to_return(status: 502, body: { error: "hedera_error" }.to_json,
                 headers: { "content-type" => "application/json" })

    assert_raises(SidecarClient::Ambiguous) { payout }
  end

  test "payout treats response loss and invalid response JSON as ambiguous" do
    stub_request(:post, "#{SIDECAR}/payout").to_raise(Net::ReadTimeout.new("lost"))
    assert_raises(SidecarClient::Ambiguous) { payout }

    stub_request(:post, "#{SIDECAR}/payout").to_return(status: 200, body: "not-json")
    assert_raises(SidecarClient::Ambiguous) { payout }
  end

  test "payout keeps definitely pre-submit failures safely retryable" do
    stub_request(:post, "#{SIDECAR}/payout").to_raise(Errno::ECONNREFUSED)
    assert_raises(SidecarClient::Unavailable) { payout }

    stub_request(:post, "#{SIDECAR}/payout")
      .to_return(status: 503, body: { error: "treasury_not_configured" }.to_json,
                 headers: { "content-type" => "application/json" })
    assert_raises(SidecarClient::Unavailable) { payout }
  end

  test "non-money sidecar calls preserve their existing retry classification" do
    stub_request(:post, "#{SIDECAR}/submit-cert").to_return(status: 200, body: "not-json")

    assert_raises(SidecarClient::Unavailable) do
      SidecarClient.new.submit_cert({ "schema" => "pwc-1" })
    end
  end

  private

  def payout
    SidecarClient.new.payout(token_id: "0.0.429274",
      transfers: [ { accountId: "0.0.7007", amount: "225000" } ], memo: "test")
  end
end
