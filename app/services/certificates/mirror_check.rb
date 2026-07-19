require "net/http"

module Certificates
  # Compares our stored certificate against the on-chain HCS message from the
  # public mirror node, field by field (jsonb key order differs — never
  # compare serialized strings). The page renders the ON-CHAIN values.
  class MirrorCheck
    Result = Struct.new(:state, :onchain, :mismatched_keys, :consensus_timestamp, :mirror_url, keyword_init: true)

    def self.call(license)
      return Result.new(state: :minting) unless license.anchored?

      mirror_url = "#{mirror_base}/api/v1/topics/#{license.hcs_topic_id}/messages/#{license.hcs_sequence_number}"
      response = Hedera::Network.get(URI(mirror_url))
      # Sequence known but the mirror hasn't indexed it yet: still propagating.
      return Result.new(state: :minting, mirror_url: mirror_url) unless response.code.to_i == 200

      message = JSON.parse(response.body)
      onchain = JSON.parse(Base64.decode64(message["message"]))
      ours = license.cert_json || {}
      mismatched = (onchain.keys | ours.keys).select { |key| onchain[key] != ours[key] }

      Result.new(
        state: mismatched.empty? ? :anchored : :mismatch,
        onchain: onchain,
        mismatched_keys: mismatched,
        consensus_timestamp: message["consensus_timestamp"],
        mirror_url: mirror_url
      )
    rescue Hedera::Network::Unavailable, JSON::ParserError
      Result.new(state: :minting, mirror_url: mirror_url) # mirror hiccup: poll again shortly
    end

    def self.mirror_base
      Hedera::Network.mirror_base
    end
  end
end
