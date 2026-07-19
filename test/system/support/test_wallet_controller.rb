# The system-test stand-in for scripts/demo-wallet.mjs: answers POST /sign with
# the PAYMENT-SIGNATURE header from the captured B1 spike payload, so browser
# checkout tests exercise the real client state machine without a key in sight.
# Routed (and required) only in the test environment — see config/routes.rb.
class TestWalletController < ActionController::Base
  skip_forgery_protection

  PAYLOAD = Rails.root.join("test/fixtures/files/x402/payment_payload.json").read.freeze
  class_attribute :sign_calls, default: 0

  def self.reset!
    self.sign_calls = 0
  end

  def sign
    if ENV["TEST_WALLET_MODE"] == "refuse"
      return render json: { error: "signing refused" }, status: :service_unavailable
    end
    # The real daemon signs params[:paymentRequired]; hold clients to sending it.
    return render json: { error: "missing paymentRequired" }, status: :bad_request unless params[:paymentRequired].present?

    self.class.sign_calls += 1
    payload = JSON.parse(PAYLOAD)
    payload["accepted"] = params.require(:paymentRequired).require(:accepts).first.to_unsafe_h
    render json: { headers: { "PAYMENT-SIGNATURE" => Base64.strict_encode64(JSON.generate(payload)) } }
  end
end
