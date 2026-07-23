require "test_helper"

class Designers::NotifierTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  setup do
    @designer = designers(:two)
  end

  test "a delivered sale notifies in-product and emails when the preference is on" do
    assert_emails 1 do
      Designers::Notifier.record_later(designer: @designer, kind: "sale_delivered",
        payload: { license_type: "personal", asset: "0.0.429274", amount_base_units: "225000", serial: 1 })
    end
    assert_equal 1, @designer.seller_notifications.where(kind: "sale_delivered").count
  end

  test "turning the sale preference off keeps the in-product notification and skips the email" do
    @designer.update!(email_on_sale: false)

    assert_no_emails do
      Designers::Notifier.record_later(designer: @designer, kind: "sale_delivered",
        payload: { license_type: "personal", asset: "0.0.429274", amount_base_units: "225000", serial: 1 })
    end
    assert_equal 1, @designer.seller_notifications.where(kind: "sale_delivered").count
  end

  test "terminal payout states email per preference; other kinds never do" do
    assert_emails 2 do
      Designers::Notifier.record_later(designer: @designer, kind: "payout_failed",
        payload: { asset: "0.0.429274", amount_base_units: "90000", error_code: "transfer_rejected" })
      Designers::Notifier.record_later(designer: @designer, kind: "payout_reconciliation_required",
        payload: { asset: "0.0.429274", amount_base_units: "90000", error_code: "ambiguous_result" })
    end

    @designer.update!(email_on_payout_issue: false)
    assert_no_emails do
      Designers::Notifier.record_later(designer: @designer, kind: "payout_failed",
        payload: { asset: "0.0.429274", amount_base_units: "90000", error_code: "transfer_rejected" })
    end

    assert_no_emails do
      Designers::Notifier.record_later(designer: @designer, kind: "payout_completed",
        payload: { asset: "0.0.429274", amount_base_units: "90000", tx_id: "0.0.9067781@1.2" })
      Designers::Notifier.record_later(designer: @designer, kind: "mesh_analysis_passed", payload: {})
      Designers::Notifier.record_later(designer: @designer, kind: "payout_destination_activated",
        payload: { hedera_account_id: "0.0.7007" })
    end
  end

  test "a raising mailer is swallowed and the notification row survives" do
    singleton = SellerNotificationMailer.singleton_class
    original = SellerNotificationMailer.method(:sale_delivered)
    singleton.define_method(:sale_delivered) { |*| raise "mail boom" }

    result = nil
    assert_nothing_raised do
      result = Designers::Notifier.record_later(designer: @designer, kind: "sale_delivered",
        payload: { license_type: "personal", asset: "0.0.429274", amount_base_units: "225000", serial: 1 })
    end

    assert_nil result
    assert_equal 1, @designer.seller_notifications.where(kind: "sale_delivered").count
  ensure
    singleton&.define_method(:sale_delivered, original) if original
  end
end
