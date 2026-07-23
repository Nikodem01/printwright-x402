module Webhooks
  # A manual test event a designer sends to verify an endpoint. It carries no
  # buyer, purchase, or license data — only a fixed marker payload — and is
  # signed and delivered through the same Sender as real events so a success
  # here proves the real path will work.
  class TestPing
    def self.call(endpoint)
      event_id = "evt_test_#{SecureRandom.hex(12)}"
      delivery = WebhookDelivery.create!(
        event_key: "webhook.test:endpoint:#{endpoint.id}:#{SecureRandom.hex(8)}",
        webhook_endpoint: endpoint, license: nil, event_id: event_id,
        event_type: "webhook.test", target_kind: "designer", url: endpoint.url,
        secret_ciphertext: endpoint.secret_ciphertext,
        payload: {
          "id" => event_id,
          "type" => "webhook.test",
          "created_at" => Time.current.utc.iso8601,
          "data" => {
            "message" => "Test event from Printwright. No purchase, license, or buyer is involved.",
            "endpoint_id" => endpoint.id
          }
        }
      )
      WebhookDeliveryJob.perform_later(delivery.id)
      delivery
    end
  end
end
