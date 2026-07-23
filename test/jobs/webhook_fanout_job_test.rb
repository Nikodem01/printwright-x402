require "test_helper"
require "webmock/minitest"

class WebhookFanoutJobTest < ActiveJob::TestCase
  setup do
    @original_resolver = Webhooks::Sender.resolver
    Webhooks::Sender.resolver = ->(_host) { [ "93.184.216.34" ] }
    @designer = designers(:one)
    @model = @designer.models3d.create!(
      title: "Fanout gear", slug: "fanout-gear-#{SecureRandom.hex(4)}",
      status: "published", file_hash: "sha256:#{'a' * 64}"
    )
    offer = @model.license_offers.create!(kind: "commercial_unit", price_cents: 25)
    @purchase = offer.purchases.create!(
      status: "settled", replay_key: SecureRandom.hex(32), buyer_hint: "0.0.9067781",
      payment_tx_id: "0.0.7@1.2", asset: "0.0.429274", amount_base_units: "250000",
      requirements_json: { "payTo" => "0.0.9584959" }
    )
    @license = License.allocate!(@purchase)
    @purchase.transition_to!(:delivered)
  end

  teardown { Webhooks::Sender.resolver = @original_resolver }

  test "a designer with no webhook endpoints still gets a durable sale notification" do
    assert_empty @designer.webhook_endpoints

    WebhookFanoutJob.perform_now(@license.id, "sale.completed")

    notification = @designer.seller_notifications.sole
    assert_equal "sale_delivered", notification.kind
    assert_equal @model, notification.model3d
    assert_equal(
      { "license_type" => "commercial_unit", "asset" => "0.0.429274",
        "amount_base_units" => "250000", "serial" => @license.serial },
      notification.payload
    )
    assert_empty WebhookDelivery.all
  end

  test "certificate anchored notifies the designer independent of any buyer webhook" do
    @license.update!(cert_json: Certificates::Builder.call(@license),
      hcs_topic_id: "0.0.9585069", hcs_sequence_number: 7)

    WebhookFanoutJob.perform_now(@license.id, "certificate.anchored")

    notification = @designer.seller_notifications.sole
    assert_equal "certificate_anchored", notification.kind
    assert_equal({ "cert_id" => @license.cert_id, "hcs_sequence_number" => 7 }, notification.payload)
  end

  test "a designer with a webhook endpoint gets both the notification and the delivery" do
    endpoint = @designer.webhook_endpoints.create!(
      url: "https://hooks.example/printwright",
      secret_ciphertext: Webhooks::SecretBox.encrypt("whsec_#{SecureRandom.hex(32)}")
    )

    WebhookFanoutJob.perform_now(@license.id, "sale.completed")

    assert_equal 1, @designer.seller_notifications.where(kind: "sale_delivered").count
    delivery = WebhookDelivery.sole
    assert_equal endpoint, delivery.webhook_endpoint
    assert_equal "sale.completed", delivery.event_type
  end

  test "a notification-insert failure never breaks the webhook fanout it runs beside" do
    @designer.webhook_endpoints.create!(
      url: "https://hooks.example/printwright",
      secret_ciphertext: Webhooks::SecretBox.encrypt("whsec_#{SecureRandom.hex(32)}")
    )
    singleton = SellerNotification.singleton_class
    original = SellerNotification.method(:record!)
    singleton.define_method(:record!) { |**| raise "boom" }

    WebhookFanoutJob.perform_now(@license.id, "sale.completed")

    assert_empty SellerNotification.all
    assert_equal 1, WebhookDelivery.count
  ensure
    singleton&.define_method(:record!, original) if original
  end
end
