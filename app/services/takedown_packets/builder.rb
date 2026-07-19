require "digest"

module TakedownPackets
  class Builder
    Error = Class.new(StandardError)

    def self.call(license, infringing_url:, details: nil)
      raise Error, "certificate is not anchored on HCS" unless license.anchored? && !license.purchase.sandbox?
      uri = URI.parse(infringing_url.to_s)
      raise Error, "infringing URL must be HTTP or HTTPS" unless uri.is_a?(URI::HTTP) && uri.host.present?

      model = license.purchase.model3d
      designer = model.designer
      mirror_url = "#{Hedera::Network.mirror_base}/api/v1/topics/#{license.hcs_topic_id}/messages/#{license.hcs_sequence_number}"
      transaction_url = "#{Hedera::Network.hashscan_base}/transaction/#{license.purchase.payment_tx_id}"
      cert_digest = "sha256:#{Digest::SHA256.hexdigest(JSON.generate(license.cert_json))}"
      Pdf.call([
        "PRINTWRIGHT COPYRIGHT / PLATFORM NOTICE TEMPLATE - NOT LEGAL ADVICE",
        "Generated #{Time.current.utc.iso8601}. This is an evidence organizer and notice template.",
        "",
        "To: Platform copyright or trust-and-safety team",
        "Reported URL: #{uri}",
        "",
        "I, #{designer.display_name}, state that I own or am authorized to act for the identified 3D model and have a good-faith belief that the reported use is not authorized.",
        "Verified public profile: #{designer.verified_profile_url.presence || 'not supplied'}",
        "Model: #{model.title} (#{model.slug})",
        "Frozen model bundle hash: #{model.file_hash}",
        "Printwright certificate: #{license.cert_id}",
        "Certificate JSON digest: #{cert_digest}",
        "License kind / serial: #{license.purchase.license_offer.kind} / #{license.serial}",
        "Settlement transaction: #{license.purchase.payment_tx_id}",
        "Transaction evidence: #{transaction_url}",
        "HCS topic / sequence: #{license.hcs_topic_id} / #{license.hcs_sequence_number}",
        "Independent mirror evidence: #{mirror_url}",
        "",
        "Additional context: #{details.to_s.first(2_000)}",
        "",
        "Requested action: Please investigate the reported listing/content, preserve relevant records, and remove or disable it if your policy and applicable law support that action.",
        "I confirm that the information in this notice is accurate to the best of my knowledge.",
        "",
        "Signature: ____________________    Date: ____________________"
      ])
    rescue URI::InvalidURIError
      raise Error, "infringing URL is invalid"
    end
  end
end
