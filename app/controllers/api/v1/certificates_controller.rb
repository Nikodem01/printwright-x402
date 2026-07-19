# Public certificate lookup: the cert JSON as submitted to HCS, plus where
# to verify it independently (mirror node + HashScan).
class Api::V1::CertificatesController < Api::V1::BaseController
  rate_limit to: 120, within: 1.minute, store: RateLimitStore, with: :api_rate_limited

  def show
    license = License.find_by!(cert_id: params[:cert_id])
    render json: {
      certificate: license.cert_json.presence,
      status: certificate_status(license),
      hcs: hcs_block(license),
      nft: nft_block(license)
    }
  end

  private

  def certificate_status(license)
    return "sandbox" if license.purchase.sandbox?

    license.anchored? ? "anchored" : "minting"
  end

  def nft_block(license)
    return nil if license.purchase.sandbox?
    return nil unless license.nft_serial.present?
    {
      token_id: license.nft_token_id,
      serial: license.nft_serial,
      claim_state: license.refresh_nft_claim_state!,
      airdrop_tx_id: license.nft_airdrop_tx_id,
      hashscan_url: "#{Hedera::Network.hashscan_base}/token/#{license.nft_token_id}/#{license.nft_serial}"
    }
  end

  def hcs_block(license)
    return nil unless license.anchored?
    if license.purchase.sandbox?
      return {
        sandbox: true,
        warning: Sandbox::Requirements::WARNING,
        topic_id: license.hcs_topic_id,
        sequence_number: license.hcs_sequence_number,
        hashscan_url: nil,
        mirror_url: api_v1_sandbox_message_url(
          topic_id: license.hcs_topic_id, sequence_number: license.hcs_sequence_number
        )
      }
    end
    mirror = Hedera::Network.mirror_base
    {
      topic_id: license.hcs_topic_id,
      sequence_number: license.hcs_sequence_number,
      hashscan_url: "#{Hedera::Network.hashscan_base}/topic/#{license.hcs_topic_id}",
      mirror_url: "#{mirror}/api/v1/topics/#{license.hcs_topic_id}/messages/#{license.hcs_sequence_number}"
    }
  end
end
