module Certificates
  # A portable, self-contained proof the buyer/agent receives at purchase and
  # can verify against Hedera without Printwright — even if our servers later
  # disappear. It is the reveal of the on-chain commitment: the full certificate
  # + the blinding nonce + the exact licensed terms bytes, plus where the
  # commitment is anchored. Recompute SHA-256(domain || nonce || JCS(cert)) and
  # confirm it equals the commitment envelope at hedera.mirror_url. Building it
  # touches no network: the verifier fetches the mirror itself.
  class Bundle
    def self.for(license)
      offer = license.purchase.license_offer
      {
        "proof_version" => 1,
        "algorithm" => Commitment::ALGORITHM,
        "certificate" => license.cert_json.presence,
        "blinding_nonce" => license.cert_salt,
        "commitment" => commitment(license),
        "terms" => {
          "version" => offer.terms_version,
          "kind" => offer.kind,
          "hash" => offer.terms_hash,
          "text" => offer.terms_text
        },
        "hedera" => hedera_block(license)
      }
    end

    def self.commitment(license)
      return nil if license.cert_json.blank? || license.cert_salt.blank?
      Commitment.digest(license.cert_json, license.cert_salt)
    end

    def self.hedera_block(license)
      return { "status" => "minting" } unless license.anchored?
      if license.purchase.sandbox?
        return {
          "sandbox" => true,
          "network" => "sandbox",
          "topic_id" => license.hcs_topic_id,
          "sequence_number" => license.hcs_sequence_number,
          "mirror_url" => Rails.application.routes.url_helpers.api_v1_sandbox_message_path(
            topic_id: license.hcs_topic_id, sequence_number: license.hcs_sequence_number
          )
        }
      end
      mirror = Hedera::Network.mirror_base
      {
        "network" => Hedera::Network.name,
        "topic_id" => license.hcs_topic_id,
        "sequence_number" => license.hcs_sequence_number,
        "mirror_url" => "#{mirror}/api/v1/topics/#{license.hcs_topic_id}/messages/#{license.hcs_sequence_number}",
        "hashscan_url" => "#{Hedera::Network.hashscan_base}/topic/#{license.hcs_topic_id}"
      }
    end
  end
end
