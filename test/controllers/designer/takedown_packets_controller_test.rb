require "test_helper"

class Designer::TakedownPacketsControllerTest < ActionDispatch::IntegrationTest
  setup do
    model = designers(:one).models3d.create!(
      title: "Packet model", slug: "packet-model", status: "published", file_hash: "sha256:packet"
    )
    offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    purchase = offer.purchases.create!(
      status: "delivered", replay_key: SecureRandom.hex(32), payment_tx_id: "0.0.123@456.789"
    )
    @license = purchase.create_license!(
      serial: 1, cert_id: "pw-000998", cert_json: { "schema" => "pwc-1" },
      hcs_topic_id: "0.0.9585069", hcs_sequence_number: 49
    )
    post session_path, params: { email_address: designers(:one).email_address, password: "password" }
  end

  test "designer downloads a packet for their certificate" do
    post designer_takedown_packet_path, params: {
      cert_id: @license.cert_id, infringing_url: "https://example.com/copy", details: "Copied."
    }

    assert_response :success
    assert_equal "application/pdf", response.media_type
    assert_includes response.headers.fetch("content-disposition"), "pw-000998.pdf"
  end

  test "designer cannot generate a packet for someone else's certificate" do
    post session_path, params: { email_address: designers(:two).email_address, password: "password" }

    post designer_takedown_packet_path, params: {
      cert_id: @license.cert_id, infringing_url: "https://example.com/copy"
    }

    assert_response :not_found
  end
end
