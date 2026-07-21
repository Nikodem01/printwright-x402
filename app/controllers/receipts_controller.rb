class ReceiptsController < ApplicationController
  rate_limit to: 60, within: 1.minute, store: RateLimitStore

  before_action :authorize_receipt

  def show
    response.set_header("Cache-Control", "no-store")
    @model = @license.purchase.model3d
    @offer = @license.purchase.license_offer
  end

  def download
    raise ActiveRecord::RecordNotFound unless @license.purchase.model3d.printable_files.any? { |file| file.file.attached? }

    grant = DownloadGrant.issue!(@license)
    redirect_to api_v1_file_path(grant.token), allow_other_host: false
  end

  private

  def authorize_receipt
    @license = License.includes(purchase: { license_offer: :model3d }).find_by!(cert_id: params[:cert_id])
    authorized = License.find_signed(params[:token], purpose: "purchase-receipt")
    unless authorized == @license && @license.purchase.delivered? && !@license.purchase.sandbox?
      raise ActiveRecord::RecordNotFound
    end
  end
end
