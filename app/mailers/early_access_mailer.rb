class EarlyAccessMailer < ApplicationMailer
  def confirmation(signup)
    @signup = signup
    mail subject: "You're on the Printwright designer list", to: signup.email_address
  end
end
