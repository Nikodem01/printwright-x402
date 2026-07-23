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

  test "email preferences update only the two notification booleans over a 303" do
    original_name = @designer.display_name

    patch email_preferences_designer_notifications_path,
      params: { designer: { email_on_sale: "0", email_on_payout_issue: "1",
                            display_name: "Forged Studio" } }

    assert_response :see_other
    @designer.reload
    assert_not @designer.email_on_sale
    assert @designer.email_on_payout_issue
    assert_equal original_name, @designer.display_name
  end

  test "the notifications page shows preference controls and the mandatory-notice boundary" do
    get designer_notifications_path

    assert_response :success
    assert_select "section#notification-email-preferences" do
      assert_select "input[name='designer[email_on_sale]']"
      assert_select "input[name='designer[email_on_payout_issue]']"
    end
    assert_includes response.body, "cannot be turned off"
  end
end
