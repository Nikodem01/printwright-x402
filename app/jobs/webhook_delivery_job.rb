class WebhookDeliveryJob < ApplicationJob
  queue_as :default

  retry_on Webhooks::Sender::Retryable, wait: :polynomially_longer, attempts: 8 do |job, error|
    delivery = WebhookDelivery.find_by(id: job.arguments.first)
    delivery&.update!(status: "failed", last_error: error.message)
    if delivery&.webhook_endpoint
      Designers::Notifier.record_later(
        designer: delivery.webhook_endpoint.designer, kind: "webhook_delivery_failed",
        payload: { url: delivery.url, event_type: delivery.event_type, last_error: error.message }
      )
    end
  end

  def perform(delivery_id)
    delivery = WebhookDelivery.find_by(id: delivery_id)
    return unless delivery

    Webhooks::Sender.call(delivery)
  rescue Webhooks::Sender::Retryable => error
    delivery&.update!(last_error: error.message)
    raise
  end
end
