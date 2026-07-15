class PasswordsMailer < ApplicationMailer
  def reset(designer)
    @designer = designer
    mail subject: "Reset your password", to: designer.email_address
  end
end
