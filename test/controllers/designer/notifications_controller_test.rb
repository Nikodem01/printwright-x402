require "test_helper"

class Designer::NotificationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @designer = designers(:one)
    sign_in_as @designer
  end

  test "authentication is required" do
    sign_out
    get designer_notifications_path
    assert_redirected_to "/login"
  end

  test "renders newest first and never another studio's notifications" do
    other = designers(:two)
    SellerNotification.record!(designer: other, kind: "sale_delivered", payload: {})
    mine_older = SellerNotification.record!(designer: @designer, kind: "sale_delivered",
      payload: { license_type: "personal", asset: "0.0.429274", amount_base_units: "225000", serial: 1 })
    mine_older.update!(created_at: 1.hour.ago)
    mine_newer = SellerNotification.record!(designer: @designer, kind: "payout_completed",
      payload: { asset: "0.0.429274", amount_base_units: "225000", tx_id: "0.0.9067781@1.2" })

    get designer_notifications_path

    assert_response :success
    assert_select "h1", text: "Notifications"
    bodies = css_select("ol.home-activity li").map(&:text)
    assert_operator bodies.index { |text| text.include?("Payout completed") },
      :<, bodies.index { |text| text.include?("Sale delivered") }
    assert_equal 2, SellerNotification.where(designer: @designer).count
    assert_not_includes response.body, "Demo Designer Two"
  end

  test "mark_all_read only touches the current designer's rows" do
    other = designers(:two)
    other_notification = SellerNotification.record!(designer: other, kind: "sale_delivered", payload: {})
    mine = SellerNotification.record!(designer: @designer, kind: "sale_delivered", payload: {})

    patch mark_all_read_designer_notifications_path

    assert_redirected_to designer_notifications_path
    assert mine.reload.read_at.present?
    assert_nil other_notification.reload.read_at
  end

  test "empty state renders honestly" do
    get designer_notifications_path
    assert_response :success
    assert_select ".empty-state", text: /No notifications yet/
  end

  test "the unread badge appears in the seller layout only" do
    SellerNotification.record!(designer: @designer, kind: "sale_delivered", payload: {})

    get designer_notifications_path
    assert_select ".dash-nav-desktop a", text: /Notifications\s*1/

    sign_out
    get "/"
    assert_response :success
    assert_no_match(/dash-nav/, response.body)
  end
end
