class Designer::WebhookEndpointsController < Designer::BaseController
  rate_limit to: 10, within: 1.minute, only: %i[create rotate_secret test], store: RateLimitStore

  def index
    @endpoints = current_designer.webhook_endpoints.order(created_at: :desc)
    deliveries = WebhookDelivery.where(
      webhook_endpoint_id: @endpoints.select(:id), target_kind: "designer"
    )
    @deliveries = deliveries.order(created_at: :desc).limit(20)
    # Per-endpoint health: most recent delivered and failed times.
    @last_delivered = deliveries.where(status: "delivered").group(:webhook_endpoint_id).maximum(:delivered_at)
    @last_failed = deliveries.where(status: "failed").group(:webhook_endpoint_id).maximum(:created_at)
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

  def pause
    set_endpoint.update!(active: false)
    redirect_to designer_webhook_endpoints_path, notice: "Endpoint paused. It will not receive new events until resumed."
  end

  def resume
    set_endpoint.update!(active: true)
    redirect_to designer_webhook_endpoints_path, notice: "Endpoint resumed. New events will be delivered again."
  end

  def rotate_secret
    @endpoint = set_endpoint
    @signing_secret = "whsec_#{SecureRandom.hex(32)}"
    @endpoint.update!(secret_ciphertext: Webhooks::SecretBox.encrypt(@signing_secret))
    @rotated = true
    render :created
  end

  def test
    Webhooks::TestPing.call(set_endpoint)
    redirect_to designer_webhook_endpoints_path(anchor: "delivery-health"),
      notice: "Test event queued. Check delivery health below; no buyer, purchase, or license is involved."
  end

  def destroy
    set_endpoint.destroy!
    redirect_to designer_webhook_endpoints_path, notice: "Webhook endpoint removed."
  end

  private

  def set_endpoint
    current_designer.webhook_endpoints.find(params[:id])
  end

  def endpoint_params
    params.require(:webhook_endpoint).permit(:url)
  end
end
