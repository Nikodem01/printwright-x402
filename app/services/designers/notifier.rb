module Designers
  # Writes the in-product seller notification for one event. Every call site
  # is already off the buyer-critical path (a background job, or a
  # designer-authenticated action), so this inserts directly rather than
  # hopping through another job — but, mirroring Analytics::Recorder, a
  # failure here is reported and swallowed: it must never fail or roll back
  # the payout, purchase, webhook, or analysis path it follows.
  class Notifier
    def self.record_later(designer:, kind:, model3d: nil, payload: {})
      SellerNotification.record!(designer: designer, kind: kind, model3d: model3d, payload: payload)
    rescue StandardError => error
      Rails.error.report(error, handled: true, context: {
        component: "designers_notifier", kind: kind.to_s, designer_id: designer&.id
      })
      nil
    end
  end
end
