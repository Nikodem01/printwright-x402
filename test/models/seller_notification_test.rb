require "test_helper"

class SellerNotificationTest < ActiveSupport::TestCase
  setup do
    @designer = designers(:one)
  end

  test "record! creates a row for a known kind, keeping only permitted payload keys" do
    notification = SellerNotification.record!(
      designer: @designer, kind: "payout_completed",
      payload: { asset: "0.0.429274", amount_base_units: "225000", tx_id: "0.0.9067781@1.2", buyer_hint: "0.0.7007" }
    )

    assert_equal %w[amount_base_units asset tx_id], notification.payload.keys.sort
    assert_not_includes notification.payload.keys, "buyer_hint"
  end

  test "an unknown kind is rejected" do
    assert_raises(ActiveRecord::RecordInvalid) do
      SellerNotification.record!(designer: @designer, kind: "buyer_shipped", payload: {})
    end
  end

  test "unread and recent scopes reflect read state and newest-first order" do
    older = SellerNotification.record!(designer: @designer, kind: "sale_delivered", payload: {})
    older.update!(created_at: 1.day.ago)
    newer = SellerNotification.record!(designer: @designer, kind: "sale_delivered", payload: {})
    newer.update!(read_at: Time.current)

    assert_equal [ older ], @designer.seller_notifications.unread.to_a
    assert_equal [ newer, older ], @designer.seller_notifications.recent.to_a
  end
end
