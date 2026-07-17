class VerifyController < ApplicationController
  allow_unauthenticated_access

  def show
    @license = License.includes(purchase: { license_offer: :model3d }).find_by(verify_slug: params[:cert_id])
    return render :not_found, status: :not_found unless @license

    @model = @license.purchase.license_offer.model3d
    @check = Certificates::MirrorCheck.call(@license)
    @cert = @check.onchain.presence || @license.cert_json # render on-chain values when we have them
  end

  # Self-contained SVG badge for embedding anywhere (designer sites, listings).
  # States nothing it can't back: the badge only links to the live check.
  def badge
    license = License.find_by(verify_slug: params[:cert_id])
    return head :not_found unless license

    render "badge", formats: :svg, layout: false,
      locals: { cert_id: license.cert_id },
      content_type: "image/svg+xml"
  end

  # Print-styled certificate (browser print-to-PDF prints it clean): the cert
  # facts, the QR to the live verify check, and the raw URLs in text form —
  # paper must not depend on this site staying up.
  def certificate
    @license = License.includes(purchase: { license_offer: :model3d }).find_by(verify_slug: params[:cert_id])
    return render :not_found, status: :not_found unless @license

    @model = @license.purchase.license_offer.model3d
    @cert = @license.cert_json
    @qr_svg = RQRCode::QRCode.new(verify_url(@license.verify_slug)).as_svg(
      module_size: 4, color: "111", use_path: true, viewbox: true
    )
    render layout: false
  end
end
