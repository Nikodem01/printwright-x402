require "test_helper"
require "webmock/minitest"

class Webhooks::TestPingTest < ActiveSupport::TestCase
  setup do
    @endpoint = designers(:one).webhook_endpoints.create!(
      url: "https://hooks.example/ping",
      secret_ciphertext: Webhooks::SecretBox.encrypt("whsec_#{SecureRandom.hex(32)}")
    )
    @previous_resolver = Webhooks::Sender.resolver
    Webhooks::Sender.resolver = ->(_host) { [ "8.8.8.8" ] }
  end

  teardown { Webhooks::Sender.resolver = @previous_resolver }

  test "creates a signed, license-less delivery the Sender can deliver end to end" do
    stub_request(:post, @endpoint.url).to_return(status: 200)

    delivery = Webhooks::TestPing.call(@endpoint)
    assert_nil delivery.license_id
    assert_equal "webhook.test", delivery.event_type

    WebhookDeliveryJob.perform_now(delivery.id)

    assert_requested(:post, @endpoint.url) do |req|
      body = JSON.parse(req.body)
      req.headers["Webhook-Signature"].start_with?("v1=") &&
        body["type"] == "webhook.test" &&
        body.dig("data", "message").present?
    end
    assert_predicate delivery.reload, :delivered?
  end

  test "each test ping is a distinct delivery, never colliding on the event key" do
    assert_difference("WebhookDelivery.count", 2) do
      Webhooks::TestPing.call(@endpoint)
      Webhooks::TestPing.call(@endpoint)
    end
  end
end
