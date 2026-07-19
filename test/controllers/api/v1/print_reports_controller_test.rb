require "test_helper"

class Api::V1::PrintReportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    model = designers(:one).models3d.create!(
      title: "Printed bracket", slug: "printed-bracket-#{SecureRandom.hex(4)}", status: "published"
    )
    offer = model.license_offers.create!(kind: "personal", price_cents: 25)
    purchase = offer.purchases.create!(
      status: "delivered", replay_key: SecureRandom.hex(32), buyer_hint: "0.0.9067781",
      payment_tx_id: "0.0.7@1.2"
    )
    @license = License.allocate!(purchase)
    @token = @license.signed_id(purpose: "print-feedback")
  end

  test "paid receipt capability records one idempotent successful print" do
    assert_difference("PrintReport.count", 1) do
      post api_v1_license_print_reports_path(@license.cert_id),
        params: { receipt_token: @token }, as: :json
    end
    assert_response :created
    assert_equal({ "cert_id" => @license.cert_id, "successful_prints" => 1 }, response.parsed_body)

    assert_no_difference("PrintReport.count") do
      post api_v1_license_print_reports_path(@license.cert_id),
        params: { receipt_token: @token }, as: :json
    end
    assert_response :success
    assert_equal 1, response.parsed_body["successful_prints"]
  end

  test "invalid and cross-license capabilities create no report" do
    other = @license.dup
    other.purchase = @license.purchase.dup.tap do |purchase|
      purchase.replay_key = SecureRandom.hex(32)
      purchase.payment_tx_id = "0.0.7@2.3"
      purchase.save!
    end
    other.serial = 2
    other.cert_id = "pw-other"
    other.verify_slug = "pw-other"
    other.save!

    [ "invalid", other.signed_id(purpose: "print-feedback") ].each do |token|
      assert_no_difference("PrintReport.count") do
        post api_v1_license_print_reports_path(@license.cert_id),
          params: { receipt_token: token }, as: :json
      end
      assert_response :not_found
    end
  end

  test "sandbox certificate can never become print-tested" do
    @license.purchase.update!(sandbox: true)

    assert_no_difference("PrintReport.count") do
      post api_v1_license_print_reports_path(@license.cert_id),
        params: { receipt_token: @token }, as: :json
    end

    assert_response :forbidden
    assert_equal "paid_license_required", response.parsed_body["error"]
  end
end
