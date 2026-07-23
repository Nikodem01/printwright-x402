require "test_helper"

class Designers::AccountExportTest < ActiveSupport::TestCase
  test "includes notification rows with only permitted payload keys, never buyer identity" do
    designer = designers(:one)
    notification = SellerNotification.record!(
      designer: designer, kind: "payout_completed",
      payload: { asset: "0.0.429274", amount_base_units: "225000", tx_id: "0.0.9067781@1.2",
                 buyer_hint: "0.0.7007" }
    )

    export = JSON.parse(Designers::AccountExport.new(designer).to_json)

    row = export.fetch("notifications").sole
    assert_equal "payout_completed", row["kind"]
    assert_equal notification.created_at.iso8601, row["created_at"]
    assert_nil row["read_at"]
    assert_equal %w[amount_base_units asset tx_id], row["payload"].keys.sort
    assert_not_includes row["payload"].keys, "buyer_hint"
  end
end
