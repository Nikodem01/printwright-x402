require "test_helper"
require "webmock/minitest"

class Heartbeat::SnapshotTest < ActiveSupport::TestCase
  TOPIC = "0.0.222".freeze
  QUERY = "https://testnet.mirrornode.hedera.com/api/v1/topics/#{TOPIC}/messages?limit=1&order=desc".freeze

  setup do
    @old_topic = ENV["HEDERA_HEARTBEAT_TOPIC_ID"]
    ENV["HEDERA_HEARTBEAT_TOPIC_ID"] = TOPIC
    Rails.cache.clear
  end

  teardown do
    ENV["HEDERA_HEARTBEAT_TOPIC_ID"] = @old_topic
    Rails.cache.clear
  end

  test "accepts only a signed-topic pwh-1 message and exposes raw proof links" do
    heartbeat = {
      schema: "pwh-1", service: "printwright", status: "alive",
      network: "hedera:testnet", observed_at: "2026-07-19T12:00:00Z"
    }
    stub_request(:get, QUERY).to_return(body: {
      messages: [ {
        topic_id: TOPIC, sequence_number: 3, consensus_timestamp: "1784450000.123456789",
        message: Base64.strict_encode64(JSON.generate(heartbeat))
      } ]
    }.to_json)

    snapshot = Heartbeat::Snapshot.call

    assert_equal [ "ok", TOPIC, 3, "2026-07-19T12:00:00Z" ],
                 snapshot.values_at(:status, :topic_id, :sequence_number, :observed_at)
    assert_includes snapshot[:message_url], "/messages/3"
    assert_includes snapshot[:hashscan_url], "/topic/#{TOPIC}"
  end

  test "invalid or unavailable mirror data is never presented as alive" do
    stub_request(:get, QUERY).to_return(body: {
      messages: [ { topic_id: TOPIC, sequence_number: 1,
                    message: Base64.strict_encode64('{"schema":"pwc-1"}') } ]
    }.to_json)
    assert_equal "unavailable", Heartbeat::Snapshot.call[:status]

    Rails.cache.clear
    stub_request(:get, QUERY).to_timeout
    assert_equal "unavailable", Heartbeat::Snapshot.call[:status]
  end

  test "an old valid message is labeled stale rather than alive" do
    heartbeat = {
      schema: "pwh-1", service: "printwright", status: "alive",
      network: "hedera:testnet", observed_at: 2.days.ago.utc.iso8601
    }
    stub_request(:get, QUERY).to_return(body: {
      messages: [ {
        topic_id: TOPIC, sequence_number: 2, consensus_timestamp: "1784277200.123456789",
        message: Base64.strict_encode64(JSON.generate(heartbeat))
      } ]
    }.to_json)

    assert_equal "stale", Heartbeat::Snapshot.call[:status]
  end

  test "missing configuration is explicit and makes no mirror request" do
    ENV.delete("HEDERA_HEARTBEAT_TOPIC_ID")

    assert_equal "not_configured", Heartbeat::Snapshot.call[:status]
    assert_not_requested :get, /mirrornode/
  end
end
