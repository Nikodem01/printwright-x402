require "application_system_test_case"

class PrintFeedbackTest < RackSystemTestCase
  setup do
    @model = designers(:one).models3d.create!(
      title: "Holder-tested hook", slug: "holder-tested-hook-#{SecureRandom.hex(4)}", status: "published"
    )
    offer = @model.license_offers.create!(kind: "personal", price_cents: 25)
    purchase = offer.purchases.create!(
      status: "delivered", replay_key: SecureRandom.hex(32), buyer_hint: "0.0.9067781",
      payment_tx_id: "0.0.7@1.2"
    )
    @license = License.allocate!(purchase)
  end

  test "print-tested badge appears only after a paid holder report" do
    visit model_page_path(@model.slug)
    assert_no_selector ".print-tested-badge"

    PrintReport.create!(license: @license)
    visit model_page_path(@model.slug)

    assert_selector ".print-tested-badge", text: "Print-tested · 1 paid holder report"
    assert_text "Self-reported; not independently inspected"
  end
end
