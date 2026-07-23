# Optional business-event email for a seller notification row. Preference
# checks live in Designers::Notifier (the single dispatch funnel); security
# notices (PayoutDestinationMailer, Rodauth) are separate and never optional.
class SellerNotificationMailer < ApplicationMailer
  helper ApplicationHelper

  def sale_delivered(notification)
    @notification = notification
    @designer = notification.designer
    @model = notification.model3d
    mail to: @designer.email_address,
      subject: "You made a sale#{@model ? " — #{@model.title}" : ""}"
  end

  def payout_issue(notification)
    @notification = notification
    @designer = notification.designer
    mail to: @designer.email_address, subject: "A payout needs your attention"
  end
end
