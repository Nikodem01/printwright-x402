require "test_helper"
require "webmock/minitest"

class HeartbeatJobTest < ActiveJob::TestCase
  SIDECAR = "http://localhost:4021".freeze

  setup do
    @old_token = ENV["SIDECAR_TOKEN"]
    @old_url = ENV["HEDERA_SIDECAR_URL"]
    ENV["SIDECAR_TOKEN"] = "test-sidecar-token"
    ENV["HEDERA_SIDECAR_URL"] = SIDECAR
  end

  teardown do
    ENV["SIDECAR_TOKEN"] = @old_token
    ENV["HEDERA_SIDECAR_URL"] = @old_url
  end

  test "submits one compact pwh-1 liveness statement to the key-holding sidecar" do
    captured = nil
    stub_request(:post, "#{SIDECAR}/submit-heartbeat")
      .with { |request| captured = request }
      .to_return(body: JSON.generate(topicId: "0.0.222", sequenceNumber: 3,
                                     transactionId: "0.0.1@2.3"))

    before = Time.current.utc
    HeartbeatJob.perform_now
    after = Time.current.utc

    assert_not_nil captured
    heartbeat = JSON.parse(captured.body).fetch("heartbeat")
    assert_equal %w[network observed_at schema service status], heartbeat.keys.sort
    assert_equal [ "pwh-1", "printwright", "alive", "hedera:testnet" ],
                 heartbeat.values_at("schema", "service", "status", "network")
    assert Time.iso8601(heartbeat.fetch("observed_at")).between?(before - 1.second, after + 1.second)
    assert_equal "Bearer test-sidecar-token", captured.headers["Authorization"]
    assert_operator captured.body.bytesize, :<, 1024
  end

  test "a sidecar outage retries instead of recording fake liveness" do
    stub_request(:post, "#{SIDECAR}/submit-heartbeat").to_timeout

    assert_enqueued_with(job: HeartbeatJob) { HeartbeatJob.perform_now }
  end
end
