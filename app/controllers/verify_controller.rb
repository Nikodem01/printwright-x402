class VerifyController < ApplicationController
  def show
    @license = License.includes(purchase: { license_offer: :model3d }).find_by(verify_slug: params[:cert_id])
    return render :not_found, status: :not_found unless @license

    @model = @license.purchase.license_offer.model3d
    @check = Certificates::MirrorCheck.call(@license)
    @cert = @check.cert.presence || @license.cert_json.presence # revealed cert; our copy while minting
  end

  # Self-contained SVG badge for embedding anywhere (designer sites, listings).
  # States nothing it can't back: the badge only links to the live check.
  def badge
    license = License.find_by(verify_slug: params[:cert_id])
    return head :not_found unless license

    render "badge", formats: :svg, layout: false,
      locals: { cert_id: license.cert_id, sandbox: license.purchase.sandbox? },
      content_type: "image/svg+xml"
  end

  # A receipt-native social image. It states the issued license serial and,
  # when configured, the license-sale cap; neither is described as a physical
  # print limit because Printwright cannot technically enforce print counts.
  def share_card
    @license = License.includes(purchase: { license_offer: { model3d: :designer } })
      .find_by(verify_slug: params[:cert_id])
    return head :not_found unless @license

    @offer = @license.purchase.license_offer
    @model = @offer.model3d
    render "share_card", formats: :svg, layout: false, content_type: "image/svg+xml"
  end

  # Print-styled certificate (browser print-to-PDF prints it clean): the cert
  # facts, the QR to the live verify check, and the raw URLs in text form —
  # paper must not depend on this site staying up. The .pdf rendering is the
  # same document made server-side, so a buyer's agent gets a file it can keep
  # without driving a browser.
  def certificate
    @license = License.includes(purchase: { license_offer: :model3d }).find_by(verify_slug: params[:cert_id])

    # A PDF has no "sorry" page to render, so every refusal on that branch is a
    # bare 404: unknown slug, or a licence whose certificate is not written yet
    # (delivery writes cert_json; the HCS anchor follows asynchronously).
    if request.format.pdf?
      return head :not_found if @license.nil? || @license.cert_json.blank?

      return send_data Certificates::Pdf.render(@license, verify_url: verify_url(@license.verify_slug)),
        filename: "printwright-certificate-#{@license.cert_id}.pdf",
        type: "application/pdf", disposition: "inline"
    end

    return render :not_found, status: :not_found unless @license

    @model = @license.purchase.license_offer.model3d
    @cert = @license.cert_json
    @qr_svg = RQRCode::QRCode.new(verify_url(@license.verify_slug)).as_svg(
      module_size: 4, color: "111", use_path: true, viewbox: true
    )
    render layout: false
  end
end
