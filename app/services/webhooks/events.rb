module Webhooks
  module Events
    def self.sale_completed(license)
      purchase = license.purchase
      return if purchase.sandbox? || !purchase.delivered?

      purchase.model3d.designer.webhook_endpoints.active.find_each do |endpoint|
        next unless endpoint.events.include?("sale.completed")

        enqueue(
          license: license, endpoint: endpoint, target_kind: "designer",
          event_type: "sale.completed", url: endpoint.url,
          secret_ciphertext: endpoint.secret_ciphertext,
          data: {
            "cert_id" => license.cert_id,
            "model_id" => purchase.model3d.id,
            "license_type" => purchase.license_offer.kind,
            "unit_serial" => license.serial,
            "buyer_hint" => purchase.buyer_hint,
            "asset" => purchase.asset,
            "amount_base_units" => purchase.amount_base_units,
            "payment_tx" => purchase.payment_tx_id,
            "verify_url" => "/verify/#{license.verify_slug}"
          }
        )
      end
    end

    def self.certificate_anchored(license)
      purchase = license.purchase
      batch = purchase.purchase_batch
      return if purchase.sandbox? || !license.anchored? || batch&.webhook_url.blank?

      enqueue(
        license: license, target_kind: "buyer", event_type: "certificate.anchored",
        url: batch.webhook_url, secret_ciphertext: batch.webhook_secret_ciphertext,
        data: {
          "cert_id" => license.cert_id,
          "certificate_url" => "/api/v1/certificates/#{license.cert_id}",
          "verify_url" => "/verify/#{license.verify_slug}",
          "hcs" => {
            "topic_id" => license.hcs_topic_id,
            "sequence_number" => license.hcs_sequence_number,
            "mirror_url" => "#{Hedera::Network.mirror_base}/api/v1/topics/#{license.hcs_topic_id}/messages/#{license.hcs_sequence_number}"
          }
        }
      )
    end

    def self.enqueue(license:, target_kind:, event_type:, url:, secret_ciphertext:, data:, endpoint: nil)
      event_id = "evt_#{Digest::SHA256.hexdigest("#{event_type}:#{license.id}")[0, 24]}"
      target_id = endpoint ? "endpoint:#{endpoint.id}" : "buyer"
      event_key = "#{event_type}:license:#{license.id}:#{target_id}"
      payload = {
        "id" => event_id,
        "type" => event_type,
        "created_at" => Time.current.utc.iso8601,
        "data" => data
      }
      attributes = {
        event_key: event_key, webhook_endpoint: endpoint, license: license, event_id: event_id,
        event_type: event_type, target_kind: target_kind, url: url,
        secret_ciphertext: secret_ciphertext, payload: payload
      }
      delivery = WebhookDelivery.find_by(event_key: event_key) || WebhookDelivery.create!(attributes)
      WebhookDeliveryJob.perform_later(delivery.id) unless delivery.delivered?
      delivery
    rescue ActiveRecord::RecordNotUnique
      retry
    end
    private_class_method :enqueue
  end
end
