class WebhookFanoutJob < ApplicationJob
  queue_as :default

  def perform(license_id, event_type)
    license = License.find(license_id)
    notify_designer(license, event_type)
    case event_type
    when "sale.completed" then Webhooks::Events.sale_completed(license)
    when "certificate.anchored" then Webhooks::Events.certificate_anchored(license)
    else raise ArgumentError, "unsupported webhook event"
    end
  end

  private

  # Runs before the webhook fanout below, and never depends on it: a
  # designer with no webhook endpoints still sees the event in-product, and
  # a webhook delivery failure can never suppress it (nor the reverse —
  # Designers::Notifier.record_later swallows its own failures).
  def notify_designer(license, event_type)
    purchase = license.purchase
    model = purchase.model3d
    case event_type
    when "sale.completed"
      Designers::Notifier.record_later(designer: model.designer, kind: "sale_delivered", model3d: model,
        payload: {
          license_type: purchase.license_offer.kind, asset: purchase.asset,
          amount_base_units: purchase.amount_base_units, serial: license.serial
        })
    when "certificate.anchored"
      Designers::Notifier.record_later(designer: model.designer, kind: "certificate_anchored", model3d: model,
        payload: { cert_id: license.cert_id, hcs_sequence_number: license.hcs_sequence_number })
    end
  end
end
