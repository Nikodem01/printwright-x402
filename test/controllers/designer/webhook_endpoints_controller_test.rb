require "test_helper"

class Designer::WebhookEndpointsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as designers(:one) }

  test "designer creates a signed sale webhook and sees its secret exactly once" do
    assert_difference("WebhookEndpoint.count", 1) do
      post designer_webhook_endpoints_path, params: {
        webhook_endpoint: { url: "https://hooks.example/printwright" }
      }
    end

    assert_response :created
    endpoint = WebhookEndpoint.sole
    secret = response.body.match(/whsec_[0-9a-f]{64}/)&.to_s
    assert secret
    assert_equal [ "sale.completed" ], endpoint.events
    assert_not_includes endpoint.secret_ciphertext, secret
    assert_equal secret, Webhooks::SecretBox.decrypt(endpoint.secret_ciphertext)

    get designer_webhook_endpoints_path
    assert_response :success
    assert_includes response.body, "hooks.example/printwright"
    assert_not_includes response.body, secret
  end

  test "invalid URL is refused and another designer cannot delete the endpoint" do
    post designer_webhook_endpoints_path, params: {
      webhook_endpoint: { url: "http://127.0.0.1/admin" }
    }
    assert_response :unprocessable_entity
    assert_equal 0, WebhookEndpoint.count

    endpoint = designers(:two).webhook_endpoints.create!(
      url: "https://hooks.example/two",
      secret_ciphertext: Webhooks::SecretBox.encrypt("whsec_#{SecureRandom.hex(32)}")
    )
    delete designer_webhook_endpoint_path(endpoint)
    assert_response :not_found
    assert endpoint.reload.persisted?
  end

  test "designer sees private-safe delivery health and queues one retry for a failed callback" do
    endpoint, delivery, purchase = failed_delivery_for(designers(:one))
    original_payload = delivery.payload.deep_dup

    get designer_webhook_endpoints_path

    assert_response :success
    assert_select "#delivery-health", text: /Recent delivery health.*sale.completed.*Failed.*callback returned HTTP 503.*Retry/m
    assert_select "form[action=?]", retry_designer_webhook_endpoint_delivery_path(endpoint, delivery)
    assert_no_match "private-buyer-wallet", response.body
    assert_no_match purchase.replay_key, response.body
    assert_no_match Webhooks::SecretBox.decrypt(endpoint.secret_ciphertext), response.body

    assert_enqueued_with(job: WebhookDeliveryJob, args: [ delivery.id ]) do
      post retry_designer_webhook_endpoint_delivery_path(endpoint, delivery)
    end
    assert_redirected_to designer_webhook_endpoints_path(anchor: "delivery-health")
    assert_equal "pending", delivery.reload.status
    assert_equal 8, delivery.attempts
    assert_equal original_payload, delivery.payload
    assert_predicate purchase.reload, :delivered?

    assert_no_enqueued_jobs only: WebhookDeliveryJob do
      post retry_designer_webhook_endpoint_delivery_path(endpoint, delivery)
    end
    follow_redirect!
    assert_select ".flash-bad", text: /already pending or delivered.*no duplicate retry/i
  end

  test "designer cannot inspect or retry another studio's failed callback" do
    endpoint, delivery = failed_delivery_for(designers(:two))

    get designer_webhook_endpoints_path
    assert_no_match endpoint.url, response.body
    assert_no_match delivery.last_error, response.body

    assert_no_enqueued_jobs only: WebhookDeliveryJob do
      post retry_designer_webhook_endpoint_delivery_path(endpoint, delivery)
    end
    assert_response :not_found
    assert_predicate delivery.reload, :failed?
  end

  test "pausing stops future events and resuming restores them" do
    endpoint = own_endpoint

    patch pause_designer_webhook_endpoint_path(endpoint)
    assert_redirected_to designer_webhook_endpoints_path
    assert_not endpoint.reload.active?

    patch resume_designer_webhook_endpoint_path(endpoint)
    assert endpoint.reload.active?
  end

  test "rotating the secret replaces it, shows it once, and invalidates the old one" do
    endpoint = own_endpoint
    old_secret = Webhooks::SecretBox.decrypt(endpoint.secret_ciphertext)

    patch rotate_secret_designer_webhook_endpoint_path(endpoint)

    assert_response :success
    new_secret = response.body.match(/whsec_[0-9a-f]{64}/)&.to_s
    assert new_secret
    assert_not_equal old_secret, new_secret
    assert_equal new_secret, Webhooks::SecretBox.decrypt(endpoint.reload.secret_ciphertext)
    assert_select "[data-controller='clipboard'] button[aria-label='Copy signing secret']"
  end

  test "send test queues one license-less test delivery with no buyer or purchase data" do
    endpoint = own_endpoint

    assert_difference("WebhookDelivery.count", 1) do
      assert_enqueued_jobs 1, only: WebhookDeliveryJob do
        post test_designer_webhook_endpoint_path(endpoint)
      end
    end

    assert_redirected_to designer_webhook_endpoints_path(anchor: "delivery-health")
    delivery = endpoint.webhook_deliveries.sole
    assert_equal "webhook.test", delivery.event_type
    assert_nil delivery.license_id
    assert_equal endpoint.url, delivery.url
    assert_equal "Test event from Printwright. No purchase, license, or buyer is involved.",
      delivery.payload.dig("data", "message")
    assert_equal %w[endpoint_id message], delivery.payload.fetch("data").keys.sort
  end

  test "another studio cannot pause, rotate, or test an endpoint" do
    endpoint = designers(:two).webhook_endpoints.create!(
      url: "https://hooks.example/two", secret_ciphertext: Webhooks::SecretBox.encrypt("whsec_#{SecureRandom.hex(32)}")
    )

    patch pause_designer_webhook_endpoint_path(endpoint)
    assert_response :not_found
    patch rotate_secret_designer_webhook_endpoint_path(endpoint)
    assert_response :not_found
    assert_no_enqueued_jobs(only: WebhookDeliveryJob) { post test_designer_webhook_endpoint_path(endpoint) }
    assert_response :not_found
    assert endpoint.reload.active?
  end

  test "the endpoint list shows per-endpoint health and status controls" do
    endpoint, delivery = failed_delivery_for(designers(:one))
    delivery.update!(status: "delivered", delivered_at: 1.hour.ago)
    endpoint.update!(active: false)

    get designer_webhook_endpoints_path

    assert_response :success
    assert_select ".catalog-meta", text: /Paused/
    assert_select ".catalog-meta", text: /Last delivered/
    assert_select "form[action=?]", resume_designer_webhook_endpoint_path(endpoint)
    assert_select "form[action=?]", test_designer_webhook_endpoint_path(endpoint)
  end

  private

  def own_endpoint
    designers(:one).webhook_endpoints.create!(
      url: "https://hooks-#{SecureRandom.hex(3)}.example/own",
      secret_ciphertext: Webhooks::SecretBox.encrypt("whsec_#{SecureRandom.hex(32)}")
    )
  end

  def failed_delivery_for(designer)
    model = designer.models3d.create!(
      title: "Webhook recovery", slug: "webhook-recovery-#{SecureRandom.hex(4)}", status: "published"
    )
    offer = model.license_offers.create!(kind: "personal", price_cents: 100)
    purchase = Purchase.create!(
      license_offer: offer, status: "verified", replay_key: SecureRandom.hex(32),
      buyer_hint: "private-buyer-wallet", amount_base_units: "1000000",
      asset: X402::Requirements.usdc_asset
    )
    purchase.transition_to!(:settled)
    purchase.transition_to!(:delivered)
    license = License.allocate!(purchase)
    secret = "whsec_#{SecureRandom.hex(32)}"
    endpoint = designer.webhook_endpoints.create!(
      url: "https://hooks-#{SecureRandom.hex(3)}.example/recovery",
      secret_ciphertext: Webhooks::SecretBox.encrypt(secret)
    )
    delivery = WebhookDelivery.create!(
      webhook_endpoint: endpoint, license: license, status: "failed", attempts: 8,
      event_type: "sale.completed", target_kind: "designer",
      event_id: "evt_#{SecureRandom.hex(12)}", event_key: "sale.completed:#{SecureRandom.hex(12)}",
      url: endpoint.url, secret_ciphertext: endpoint.secret_ciphertext,
      payload: { "data" => { "buyer_hint" => purchase.buyer_hint } },
      last_error: "callback returned HTTP 503"
    )
    [ endpoint, delivery, purchase ]
  end
end
