require "net/http"

module Certificates
  # Verifies a license certificate against its on-chain record from the public
  # mirror node. New certificates publish only an opaque salted commitment
  # (Certificates::Commitment): the holder reveals the off-chain cert + salt and
  # we recompute the hash to prove it matches the on-chain commitment. Certs
  # anchored before that change carry the full cert on-chain and are still
  # verified field-by-field. The page renders whichever the ledger can back.
  class MirrorCheck
    Result = Struct.new(
      :state, :cert, :onchain_commitment, :expected_commitment, :legacy,
      :mismatched_keys, :consensus_timestamp, :mirror_url, keyword_init: true
    )

    def self.call(license)
      return Result.new(state: :minting, mismatched_keys: []) unless license.anchored?
      return sandbox_result(license) if license.purchase.sandbox?

      mirror_url = "#{mirror_base}/api/v1/topics/#{license.hcs_topic_id}/messages/#{license.hcs_sequence_number}"
      response = Hedera::Network.get(URI(mirror_url))
      # Sequence known but the mirror hasn't indexed it yet: still propagating.
      return Result.new(state: :minting, mismatched_keys: [], mirror_url: mirror_url) unless response.code.to_i == 200

      message = JSON.parse(response.body)
      onchain = JSON.parse(Base64.decode64(message["message"]))
      verify(license, onchain, message["consensus_timestamp"], mirror_url)
    rescue Hedera::Network::Unavailable, JSON::ParserError
      Result.new(state: :minting, mismatched_keys: [], mirror_url: mirror_url) # mirror hiccup: poll again shortly
    end

    # The sandbox imitates the same commitment envelope on a local throwaway
    # topic so integrators rehearse the real reveal-and-prove flow.
    def self.sandbox_result(license)
      path = Rails.application.routes.url_helpers.api_v1_sandbox_message_path(
        topic_id: license.hcs_topic_id, sequence_number: license.hcs_sequence_number
      )
      onchain = JSON.parse(Base64.decode64(Sandbox::Topic.message(license)[:message]))
      verify(license, onchain, format("%.9f", license.updated_at.to_r), path, sandbox: true)
    end

    def self.verify(license, onchain, consensus_timestamp, mirror_url, sandbox: false)
      base = { consensus_timestamp: consensus_timestamp, mirror_url: mirror_url }
      if Certificates::Commitment.envelope?(onchain)
        expected = Certificates::Commitment.digest(license.cert_json, license.cert_salt)
        matched = onchain["commitment"] == expected
        Result.new(
          state: sandbox ? :sandbox : (matched ? :anchored : :mismatch),
          cert: license.cert_json, onchain_commitment: onchain["commitment"],
          expected_commitment: expected, legacy: false, mismatched_keys: [], **base
        )
      else
        ours = license.cert_json || {}
        mismatched = (onchain.keys | ours.keys).select { |key| onchain[key] != ours[key] }
        Result.new(
          state: sandbox ? :sandbox : (mismatched.empty? ? :anchored : :mismatch),
          cert: onchain, onchain_commitment: nil, expected_commitment: nil,
          legacy: true, mismatched_keys: mismatched, **base
        )
      end
    end

    def self.mirror_base
      Hedera::Network.mirror_base
    end
  end
end
