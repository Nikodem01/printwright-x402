require "test_helper"
require "webmock/minitest"

class WebhookDeliveryJobTest < ActiveJob::TestCase
  setup do
    @original_resolver = Webhooks::Sender.resolver
    Webhooks::Sender.resolver = ->(_host) { [ "93.184.216.34" ] }
    designer = designers(:one)
    model = designer.models3d.create!(
      title: "Webhook gear", slug: "webhook-gear-#{SecureRandom.hex(4)}",
      status: "published", file_hash: "sha256:#{'a' * 64}"
    )
    offer = model.license_offers.create!(kind: "commercial_unit", price_cents: 25)
    @purchase = offer.purchases.create!(
      status: "settled", replay_key: SecureRandom.hex(32), buyer_hint: "0.0.9067781",
      payment_tx_id: "0.0.7@1.2", asset: "0.0.429274", amount_base_units: "250000",
      requirements_json: { "payTo" => "0.0.9584959" }
    )
    @license = License.allocate!(@purchase)
    @purchase.transition_to!(:delivered)
    @secret = "whsec_#{SecureRandom.hex(32)}"
    @endpoint = designer.webhook_endpoints.create!(
      url: "https://hooks.example/printwright",
      secret_ciphertext: Webhooks::SecretBox.encrypt(@secret)
    )
  end

  teardown { Webhooks::Sender.resolver = @original_resolver }

  test "paid sale event is signed, delivered, and idempotent" do
    Webhooks::Events.sale_completed(@license)
    Webhooks::Events.sale_completed(@license)
    assert_equal 1, WebhookDelivery.count
    delivery = WebhookDelivery.sole
    assert_equal "sale.completed", delivery.event_type
    assert_equal @license.cert_id, delivery.payload.dig("data", "cert_id")

    request_body = nil
    signature_headers = nil
    stub_request(:post, @endpoint.url).with do |request|
      request_body = request.body
      signature_headers = request.headers
      true
    end.to_return(status: 204)

    WebhookDeliveryJob.perform_now(delivery.id)

    delivery.reload
    assert_equal "delivered", delivery.status
    assert_equal 1, delivery.attempts
    signed = "#{signature_headers.fetch('Webhook-Id')}.#{signature_headers.fetch('Webhook-Timestamp')}.#{request_body}"
    expected = OpenSSL::HMAC.hexdigest("SHA256", @secret, signed)
    assert_equal "v1=#{expected}", signature_headers.fetch("Webhook-Signature")
    assert_equal delivery.event_id, JSON.parse(request_body)["id"]
  end

  test "failed delivery records the attempt and enqueues a bounded retry" do
    Webhooks::Events.sale_completed(@license)
    delivery = WebhookDelivery.sole
    stub_request(:post, @endpoint.url).to_return(status: 503, body: "try later")

    assert_enqueued_with(job: WebhookDeliveryJob, args: [ delivery.id ]) do
      WebhookDeliveryJob.perform_now(delivery.id)
    end

    assert_equal [ "pending", 1 ], delivery.reload.values_at("status", "attempts")
    assert_includes delivery.last_error, "503"
  end

  test "private DNS is blocked before any callback request" do
    Webhooks::Sender.resolver = ->(_host) { [ "127.0.0.1" ] }
    Webhooks::Events.sale_completed(@license)
    delivery = WebhookDelivery.sole

    assert_enqueued_with(job: WebhookDeliveryJob, args: [ delivery.id ]) do
      WebhookDeliveryJob.perform_now(delivery.id)
    end

    assert_includes delivery.reload.last_error, "non-public"
    assert_not_requested :post, @endpoint.url
  end

  test "buyer certificate event requires a paid batch callback and an HCS anchor" do
    batch_secret = "buyer_#{SecureRandom.hex(32)}"
    batch = PurchaseBatch.create!(
      status: "delivered", replay_key: SecureRandom.hex(32), payment_tx_id: "0.0.7@2.3",
      webhook_url: "https://buyer.example/certificates",
      webhook_secret_ciphertext: Webhooks::SecretBox.encrypt(batch_secret)
    )
    @purchase.update!(purchase_batch: batch, batch_position: 0, payment_tx_id: batch.payment_tx_id)

    assert_no_difference("WebhookDelivery.count") do
      Webhooks::Events.certificate_anchored(@license)
    end

    @license.update!(
      cert_json: Certificates::Builder.call(@license),
      hcs_topic_id: "0.0.9585069", hcs_sequence_number: 61
    )
    assert_difference("WebhookDelivery.count", 1) do
      Webhooks::Events.certificate_anchored(@license)
      Webhooks::Events.certificate_anchored(@license)
    end

    delivery = WebhookDelivery.order(:id).last
    assert_equal [ "certificate.anchored", "buyer" ], [ delivery.event_type, delivery.target_kind ]
    assert_equal 61, delivery.payload.dig("data", "hcs", "sequence_number")
    assert_equal batch_secret, Webhooks::SecretBox.decrypt(delivery.secret_ciphertext)
  end
end
