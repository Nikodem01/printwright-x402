class VerifyController < ApplicationController
  allow_unauthenticated_access

  def show
    @license = License.includes(purchase: { license_offer: :model3d }).find_by(verify_slug: params[:cert_id])
    return render :not_found, status: :not_found unless @license

    @model = @license.purchase.license_offer.model3d
    @check = Certificates::MirrorCheck.call(@license)
    @cert = @check.onchain.presence || @license.cert_json # render on-chain values when we have them
  end
end
