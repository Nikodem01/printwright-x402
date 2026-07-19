module Heartbeat
  class Snapshot
    EXPECTED_KEYS = %w[network observed_at schema service status].freeze

    def self.call = new.call

    def call
      topic_id = ENV["HEDERA_HEARTBEAT_TOPIC_ID"]
      return unavailable("not_configured", topic_id) if topic_id.blank?
      raise ArgumentError, "invalid heartbeat topic" unless topic_id.match?(/\A\d+\.\d+\.\d+\z/)

      Rails.cache.fetch([ "heartbeat", Hedera::Network.name, topic_id ], expires_in: 1.minute) do
        path = "/api/v1/topics/#{topic_id}/messages?limit=1&order=desc"
        response = Hedera::Network.get(path)
        raise Hedera::Network::Unavailable, "mirror HTTP #{response.code}" unless response.code.to_i == 200

        latest = JSON.parse(response.body).fetch("messages").first
        raise ArgumentError, "heartbeat topic is empty" unless latest

        payload = validate_message(latest, topic_id)
        observed_at = Time.iso8601(payload.fetch("observed_at"))
        raise ArgumentError, "heartbeat is dated in the future" if observed_at > 5.minutes.from_now
        sequence = Integer(latest.fetch("sequence_number"))
        {
          status: observed_at < 12.hours.ago ? "stale" : "ok",
          topic_id: topic_id,
          sequence_number: sequence,
          observed_at: payload.fetch("observed_at"),
          consensus_timestamp: latest.fetch("consensus_timestamp"),
          message_url: "#{Hedera::Network.mirror_base}/api/v1/topics/#{topic_id}/messages/#{sequence}",
          hashscan_url: "#{Hedera::Network.hashscan_base}/topic/#{topic_id}"
        }
      end
    rescue Hedera::Network::Unavailable, JSON::ParserError, KeyError, ArgumentError
      unavailable("unavailable", topic_id)
    end

    private

    def validate_message(message, topic_id)
      payload = JSON.parse(Base64.strict_decode64(message.fetch("message")))
      valid = message.fetch("topic_id") == topic_id &&
        Integer(message.fetch("sequence_number")).positive? &&
        payload.keys.sort == EXPECTED_KEYS &&
        payload.values_at("schema", "service", "status", "network") ==
          [ "pwh-1", "printwright", "alive", Hedera::Network.caip2 ]
      Time.iso8601(payload.fetch("observed_at"))
      raise ArgumentError, "invalid pwh-1 heartbeat" unless valid

      payload
    end

    def unavailable(status, topic_id)
      {
        status: status,
        topic_id: topic_id,
        sequence_number: nil,
        observed_at: nil,
        consensus_timestamp: nil,
        message_url: nil,
        hashscan_url: topic_id && "#{Hedera::Network.hashscan_base}/topic/#{topic_id}"
      }
    end
  end
end
