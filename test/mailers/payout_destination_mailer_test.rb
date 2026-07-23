require "test_helper"

class PayoutDestinationMailerTest < ActionMailer::TestCase
  test "change and hold notices go to the verified account channel with recovery details" do
    designer = designers(:two)
    requested = PayoutDestinationMailer.change_requested(designer, "0.0.7007")
    held = PayoutDestinationMailer.safety_hold(designer, "0.0.7007", 24.hours.from_now)

    assert_equal [ designer.email_address ], requested.to
    assert_includes requested.text_part.body.decoded, "active payout destination has not changed"
    assert_includes requested.text_part.body.decoded, "cancel the pending change"
    assert_includes held.text_part.body.decoded, "current payout destination remains active"
    assert_includes held.text_part.body.decoded, "Safety hold ends"
  end

  test "activation notice limits the change to future payouts and preserves buyer rights" do
    mail = PayoutDestinationMailer.activated(designers(:two), "0.0.7007")
    body = mail.text_part.body.decoded

    assert_includes body, "Only eligible future designer payouts use this destination"
    assert_includes body, "Buyer checkout, delivered licenses, receipts, certificates, and downloads are unchanged"
  end
end
