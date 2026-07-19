class Designer::TakedownPacketsController < Designer::BaseController
  def new
    @cert_id = params[:cert_id]
  end

  def create
    license = License.find_by!(cert_id: params[:cert_id])
    raise ActiveRecord::RecordNotFound unless license.purchase.model3d.designer_id == current_designer.id

    pdf = TakedownPackets::Builder.call(
      license, infringing_url: params[:infringing_url], details: params[:details]
    )
    send_data pdf, filename: "printwright-takedown-#{license.cert_id}.pdf",
      type: "application/pdf", disposition: "attachment"
  rescue TakedownPackets::Builder::Error => error
    redirect_to new_designer_takedown_packet_path(cert_id: params[:cert_id]), alert: error.message
  end
end
