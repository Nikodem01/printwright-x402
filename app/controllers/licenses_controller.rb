# Public permalinks for the canonical license texts. The .txt format serves
# the EXACT canonical bytes, so anyone can recompute the certificate's
# terms_hash:  curl -s <url>.txt | sha256sum
class LicensesController < ApplicationController
  allow_unauthenticated_access

  def show
    @version = params[:version]
    @kind = params[:kind]
    raise ActionController::RoutingError, "no such license" unless Licensing::Documents.exists?(@version, @kind)

    @text = Licensing::Documents.text(@version, @kind)
    @hash = Licensing::Documents.hash(@version, @kind)
    respond_to do |format|
      format.html
      format.text { render plain: @text }
    end
  rescue ActionController::RoutingError
    render file: Rails.public_path.join("404.html"), status: :not_found, layout: false
  end
end
