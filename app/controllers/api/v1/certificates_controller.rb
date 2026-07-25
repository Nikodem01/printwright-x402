# Public certificate lookup keyed by the unguessable cert_id: returns the
# portable proof bundle — the reveal of the on-chain commitment (certificate +
# blinding nonce + exact terms + where it is anchored). A holder-initiated
# disclosure, since cert_id is not enumerable. Recompute
# SHA-256(domain || nonce || JCS(certificate)) and confirm it equals the
# commitment envelope at hedera.mirror_url — no trust in this endpoint's verdict.
class Api::V1::CertificatesController < Api::V1::BaseController
  rate_limit to: 120, within: 1.minute, store: RateLimitStore, with: :api_rate_limited

  def show
    license = License.find_by!(cert_id: params[:cert_id])
    render json: Certificates::Bundle.for(license).merge("status" => certificate_status(license))
  end

  private

  def certificate_status(license)
    return "sandbox" if license.purchase.sandbox?

    license.anchored? ? "anchored" : "minting"
  end
end
