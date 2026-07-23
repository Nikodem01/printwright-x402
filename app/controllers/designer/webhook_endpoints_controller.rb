class Designer::WebhookEndpointsController < Designer::BaseController
  def index
    @endpoints = current_designer.webhook_endpoints.order(created_at: :desc)
    @deliveries = WebhookDelivery.where(
      webhook_endpoint_id: @endpoints.select(:id), target_kind: "designer"
    ).order(created_at: :desc).limit(20)
  end

  def new
    @endpoint = current_designer.webhook_endpoints.build
  end

  def create
    @endpoint = current_designer.webhook_endpoints.build(endpoint_params)
    @signing_secret = "whsec_#{SecureRandom.hex(32)}"
    @endpoint.secret_ciphertext = Webhooks::SecretBox.encrypt(@signing_secret)
    if @endpoint.save
      render :created, status: :created
    else
      @signing_secret = nil
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    current_designer.webhook_endpoints.find(params[:id]).destroy!
    redirect_to designer_webhook_endpoints_path, notice: "Webhook endpoint removed."
  end

  private

  def endpoint_params
    params.require(:webhook_endpoint).permit(:url)
  end
end
