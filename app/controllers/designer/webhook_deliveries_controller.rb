class Designer::WebhookDeliveriesController < Designer::BaseController
  rate_limit to: 10, within: 1.minute, only: :retry, store: RateLimitStore

  def retry
    endpoint = current_designer.webhook_endpoints.find(params[:webhook_endpoint_id])
    delivery = endpoint.webhook_deliveries.find(params[:id])
    queued = false
    delivery.with_lock do
      if delivery.failed?
        delivery.update!(status: "pending")
        queued = true
      end
    end
    WebhookDeliveryJob.perform_later(delivery.id) if queued

    redirect_to designer_webhook_endpoints_path(anchor: "delivery-health"),
      (queued ? { notice: "Webhook retry queued. Buyer payment and delivery are unchanged." } :
        { alert: "This webhook is already pending or delivered, so no duplicate retry was queued." })
  end
end
