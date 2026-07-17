# Anchors a license certificate on HCS, after delivery — a sidecar outage
# must never block or fail a paid purchase; this job just retries until the
# cert lands, then backfills the sequence number.
class CertMintJob < ApplicationJob
  queue_as :default
  retry_on SidecarClient::Unavailable, wait: :polynomially_longer, attempts: 10

  def perform(license_id)
    license = License.find(license_id)
    return if license.anchored?

    license.update!(cert_json: Certificates::Builder.call(license)) if license.cert_json.blank?

    receipt = SidecarClient.new.submit_cert(license.cert_json)
    license.update!(
      hcs_topic_id: receipt["topicId"],
      hcs_sequence_number: receipt["sequenceNumber"]
    )
    # The anchored cert is the record; the NFT is the holdable proof of it.
    NftMintJob.perform_later(license.id)
  end
end
