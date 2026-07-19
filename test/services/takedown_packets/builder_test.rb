require "test_helper"

class TakedownPackets::BuilderTest < ActiveSupport::TestCase
  setup do
    model = designers(:one).models3d.create!(
      title: "Protected model", slug: "protected-model", status: "published", file_hash: "sha256:model"
    )
    offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    purchase = offer.purchases.create!(
      status: "delivered", replay_key: SecureRandom.hex(32), payment_tx_id: "0.0.123@456.789"
    )
    @license = purchase.create_license!(
      serial: 1, cert_id: "pw-000999", cert_json: { "schema" => "pwc-1", "model_hash" => model.file_hash },
      hcs_topic_id: "0.0.9585069", hcs_sequence_number: 50
    )
  end

  test "builds a PDF notice with certificate and independent ledger evidence" do
    pdf = TakedownPackets::Builder.call(
      @license, infringing_url: "https://example.com/copied-model", details: "Copied listing."
    )

    assert pdf.start_with?("%PDF-1.4")
    assert_includes pdf, "pw-000999"
    assert_includes pdf, "0.0.123@456.789"
    assert_includes pdf, "/topics/0.0.9585069/messages/50"
    assert_includes pdf, "NOT LEGAL ADVICE"
  end

  test "refuses a certificate without HCS evidence" do
    @license.update!(hcs_sequence_number: nil)

    error = assert_raises(TakedownPackets::Builder::Error) do
      TakedownPackets::Builder.call(@license, infringing_url: "https://example.com/copy")
    end

    assert_includes error.message, "not anchored"
  end
end
