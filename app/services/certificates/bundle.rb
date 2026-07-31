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
      {
        "proof_version" => license.cert_json.presence&.fetch("v", 1) || 1,
        "algorithm" => Commitment::ALGORITHM,
        "certificate" => license.cert_json.presence,
        "blinding_nonce" => license.cert_salt,
        "commitment" => commitment(license),
        "terms" => terms(license),
        "hedera" => hedera_block(license)
      }
    end

    # The bytes the certificate actually committed to — resolved from the
    # anchored terms_hash, not from the offer as it stands today. An offer can
    # move to a newer terms version after this license was sold; the grant this
    # buyer holds is the one they paid under, and it must still hash correctly.
    def self.terms(license)
      offer = license.purchase.license_offer
      anchored = license.cert_json.presence&.dig("terms_hash")
      version = anchored.present? ? Licensing::Documents.version_for_hash(offer.kind, anchored) : nil

      return { "version" => offer.terms_version, "kind" => offer.kind,
               "hash" => offer.terms_hash, "text" => offer.terms_text } if version.nil?

      { "version" => version, "kind" => offer.kind, "hash" => anchored,
        "text" => Licensing::Documents.text(version, offer.kind) }
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
        "mirror_url" => "#{mirror}/api/v1/topics/#{license.hcs_topic_id}/messages/#{license.hcs_sequence_number}"
      }
    end
  end
end
