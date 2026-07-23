require "test_helper"

class SellerNotificationMailerTest < ActionMailer::TestCase
  setup do
    @designer = designers(:two)
    @model = @designer.models3d.create!(title: "Mailed Sale Clip",
      slug: "mailed-sale-clip-#{SecureRandom.hex(4)}", status: "published")
  end

  test "sale email carries the sale facts, never buyer identity" do
    notification = SellerNotification.record!(designer: @designer, kind: "sale_delivered",
      model3d: @model,
      payload: { license_type: "commercial_unit", asset: "0.0.429274",
                 amount_base_units: "225000", serial: 3 })

    mail = SellerNotificationMailer.sale_delivered(notification)
    body = mail.text_part.body.decoded

    assert_equal [ @designer.email_address ], mail.to
    assert_includes mail.subject, "Mailed Sale Clip"
    assert_includes body, "Commercial unit license, unit 3"
    assert_includes body, "0.22 USDC"
    assert_includes body, "immutable ledger"
    assert_not_includes mail.html_part.body.decoded + body, "buyer"
  end

  test "payout failure email says the share stays owed and buyers are unaffected" do
    notification = SellerNotification.record!(designer: @designer, kind: "payout_failed",
      payload: { asset: "0.0.429274", amount_base_units: "90000", error_code: "transfer_rejected" })

    body = SellerNotificationMailer.payout_issue(notification).text_part.body.decoded

    assert_includes body, "could not be sent (transfer_rejected)"
    assert_includes body, "recorded as owed"
    assert_includes body, "purchase and delivered license are unaffected"
  end

  test "reconciliation email explains why nothing retries automatically" do
    notification = SellerNotification.record!(designer: @designer,
      kind: "payout_reconciliation_required",
      payload: { asset: "0.0.429274", amount_base_units: "90000",
                 tx_id: "0.0.9067781@1.2", error_code: "ambiguous_result" })

    body = SellerNotificationMailer.payout_issue(notification).text_part.body.decoded

    assert_includes body, "unconfirmed transfer result"
    assert_includes body, "No one will retry it automatically"
    assert_includes body, "cannot be paid twice"
  end
end
