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
end
