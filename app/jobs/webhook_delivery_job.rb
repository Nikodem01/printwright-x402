class WebhookDeliveryJob < ApplicationJob
  queue_as :default

  retry_on Webhooks::Sender::Retryable, wait: :polynomially_longer, attempts: 8 do |job, error|
    delivery = WebhookDelivery.find_by(id: job.arguments.first)
    delivery&.update!(status: "failed", last_error: error.message)
  end

  def perform(delivery_id)
    delivery = WebhookDelivery.find(delivery_id)
    Webhooks::Sender.call(delivery)
  rescue Webhooks::Sender::Retryable => error
    delivery&.update!(last_error: error.message)
    raise
  end
end
