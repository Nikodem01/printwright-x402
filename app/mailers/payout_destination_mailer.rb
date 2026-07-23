class PayoutDestinationMailer < ApplicationMailer
  def change_requested(designer, account_id)
    @designer = designer
    @account_id = account_id
    mail to: designer.email_address, subject: "Payout destination change requested"
  end

  def safety_hold(designer, account_id, hold_until)
    @designer = designer
    @account_id = account_id
    @hold_until = hold_until
    mail to: designer.email_address, subject: "Payout destination is in safety hold"
  end

  def activated(designer, account_id)
    @designer = designer
    @account_id = account_id
    mail to: designer.email_address, subject: "Payout destination activated"
  end

  def cancelled(designer, account_id)
    @designer = designer
    @account_id = account_id
    mail to: designer.email_address, subject: "Payout destination change cancelled"
  end
end
