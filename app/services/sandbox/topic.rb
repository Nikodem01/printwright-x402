module Sandbox
  # Local throwaway topic: the same base64 message envelope as a Hedera mirror
  # response, backed by the sandbox license row instead of a real consensus
  # submission. Sequence numbers are local license ids and have no chain value.
  module Topic
    ID = "printwright-sandbox".freeze

    def self.anchor!(license)
      certificate = Certificates::Builder.call(license).merge(
        "sandbox" => true,
        "warning" => Requirements::WARNING
      )
      license.update!(
        cert_json: certificate,
        hcs_topic_id: ID,
        hcs_sequence_number: license.id
      )
    end

    def self.message(license)
      {
        sandbox: true,
        warning: Requirements::WARNING,
        topic_id: ID,
        sequence_number: license.hcs_sequence_number,
        consensus_timestamp: format("%.9f", license.updated_at.to_r),
        message: Base64.strict_encode64(JSON.generate(license.cert_json))
      }
    end
  end
end
