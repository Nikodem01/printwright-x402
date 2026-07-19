class WebhookFanoutJob < ApplicationJob
  queue_as :default

  def perform(license_id, event_type)
    license = License.find(license_id)
    case event_type
    when "sale.completed" then Webhooks::Events.sale_completed(license)
    when "certificate.anchored" then Webhooks::Events.certificate_anchored(license)
    else raise ArgumentError, "unsupported webhook event"
    end
  end
end
