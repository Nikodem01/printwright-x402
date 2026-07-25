# Anchors a license certificate on HCS, after delivery — a sidecar outage
# must never block or fail a paid purchase; this job just retries until the
# cert lands, then backfills the sequence number.
class CertMintJob < ApplicationJob
  queue_as :default
  retry_on SidecarClient::Unavailable, wait: :polynomially_longer, attempts: 10

  def perform(license_id)
    license = License.find(license_id)
    return if license.purchase.sandbox?
    if license.anchored?
      WebhookFanoutJob.perform_later(license.id, "certificate.anchored")
      return
    end

    license.update!(cert_json: Certificates::Builder.call(license)) if license.cert_json.blank?
    # Legacy licenses created before the commitment migration carry no salt.
    license.update!(cert_salt: SecureRandom.hex(32)) if license.cert_salt.blank?

    # Publish only an opaque, salted commitment to the certificate — never the
    # cert itself. The full cert + salt stay off-chain; /verify reveals and
    # re-hashes them to prove they match this on-chain commitment.
    receipt = SidecarClient.new.submit_cert(
      Certificates::Commitment.envelope(license.cert_json, license.cert_salt)
    )
    license.update!(
      hcs_topic_id: receipt["topicId"],
      hcs_sequence_number: receipt["sequenceNumber"]
    )
    WebhookFanoutJob.perform_later(license.id, "certificate.anchored")
  end
end
