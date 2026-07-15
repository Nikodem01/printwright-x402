# Public certificate lookup: the cert JSON as submitted to HCS, plus where
# to verify it independently (mirror node + HashScan).
class Api::V1::CertificatesController < Api::V1::BaseController
  def show
    license = License.find_by!(cert_id: params[:cert_id])
    render json: {
      certificate: license.cert_json.presence,
      status: license.anchored? ? "anchored" : "minting",
      hcs: hcs_block(license)
    }
  end

  private

  def hcs_block(license)
    return nil unless license.anchored?
    mirror = ENV.fetch("MIRROR_NODE_URL", "https://testnet.mirrornode.hedera.com")
    {
      topic_id: license.hcs_topic_id,
      sequence_number: license.hcs_sequence_number,
      hashscan_url: "https://hashscan.io/testnet/topic/#{license.hcs_topic_id}",
      mirror_url: "#{mirror}/api/v1/topics/#{license.hcs_topic_id}/messages/#{license.hcs_sequence_number}"
    }
  end
end
