# The durable side of delivery. The signed receipt token never expires and needs
# no account, so this — not the download grant in the purchase response — is how
# a buyer or their agent gets the files back a month or a year later.
class ReceiptsController < ApplicationController
  include NoIndex

  rate_limit to: 60, within: 1.minute, store: RateLimitStore

  before_action :authorize_receipt

  def show
    response.set_header("Cache-Control", "no-store")
    @model = @license.purchase.model3d
    @offer = @license.purchase.license_offer
    @files = @model.deliverable_files
    respond_to do |format|
      format.html
      # Whatever the receipt page lets a human do, an agent does over the same
      # URL with the same token: the machine-readable file list with live
      # download URLs, no HTML scraping and no browser.
      format.json { render json: receipt_payload }
    end
  end

  # `f` names a part of a multi-part bundle; without it the buyer gets the first
  # part, as this link always has. Both re-mint a grant, so a receipt keeps
  # working long after the grant handed out at purchase time lapsed.
  def download
    deliverable = @license.purchase.model3d.deliverable_files
    index = params.key?(:f) ? Integer(params[:f], exception: false) : deliverable.dig(0, 0)
    raise ActiveRecord::RecordNotFound unless deliverable.any? { |position, _| position == index }

    redirect_to api_v1_file_path(DownloadGrant.for(@license).token, f: index), allow_other_host: false
  end

  private

  def receipt_payload
    grant = DownloadGrant.for(@license)
    model = @license.purchase.model3d
    {
      cert_id: @license.cert_id,
      serial: @license.serial,
      kind: @license.purchase.license_offer.kind,
      model: { id: model.id, slug: model.slug, title: model.title },
      transaction_id: @license.purchase.payment_tx_id,
      files: @files.map do |index, file|
        { kind: file.kind, url: api_v1_file_url(grant.token, f: index), expires_at: grant.expires_at.iso8601 }
      end,
      verify_url: verify_url(@license.verify_slug),
      bundle_url: api_v1_certificate_url(@license.cert_id),
      certificate_pdf_url: verify_certificate_pdf_url(@license.verify_slug),
      model_updates: {
        url: api_v1_license_latest_version_url(@license.cert_id),
        download_url: api_v1_license_latest_version_file_url(@license.cert_id),
        receipt_token: @license.signed_id(purpose: "model-updates")
      },
      print_feedback: {
        url: api_v1_license_print_reports_url(@license.cert_id),
        receipt_token: @license.signed_id(purpose: "print-feedback")
      }
    }
  end

  def authorize_receipt
    @license = License.includes(purchase: { license_offer: :model3d }).find_by!(cert_id: params[:cert_id])
    authorized = License.find_signed(params[:token], purpose: "purchase-receipt")
    unless authorized == @license && @license.purchase.delivered? && !@license.purchase.sandbox?
      raise ActiveRecord::RecordNotFound
    end
  end
end
