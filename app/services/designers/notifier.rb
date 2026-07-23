module Designers
  # Writes the in-product seller notification for one event. Every call site
  # is already off the buyer-critical path (a background job, or a
  # designer-authenticated action), so this inserts directly rather than
  # hopping through another job — but, mirroring Analytics::Recorder, a
  # failure here is reported and swallowed: it must never fail or roll back
  # the payout, purchase, webhook, or analysis path it follows.
  class Notifier
    # Business-event kinds that also send an optional email, gated by the
    # named designer preference. Security notices (payout destination,
    # account access) are separate mailers and never optional.
    EMAILED_KINDS = {
      "sale_delivered" => :email_on_sale,
      "payout_failed" => :email_on_payout_issue,
      "payout_reconciliation_required" => :email_on_payout_issue
    }.freeze

    def self.record_later(designer:, kind:, model3d: nil, payload: {})
      notification = SellerNotification.record!(designer: designer, kind: kind,
        model3d: model3d, payload: payload)
      deliver_email(notification)
      notification
    rescue StandardError => error
      Rails.error.report(error, handled: true, context: {
        component: "designers_notifier", kind: kind.to_s, designer_id: designer&.id
      })
      nil
    end

    def self.deliver_email(notification)
      preference = EMAILED_KINDS[notification.kind]
      return unless preference && notification.designer.public_send(preference)

      if notification.kind == "sale_delivered"
        SellerNotificationMailer.sale_delivered(notification).deliver_later
      else
        SellerNotificationMailer.payout_issue(notification).deliver_later
      end
    end
    private_class_method :deliver_email
  end
end
