class PasswordsMailer < ApplicationMailer
  def reset(designer)
    @designer = designer
    @password_reset_token = designer.password_reset_token
    mail subject: "Reset your Printwright password", to: designer.email_address
  end
end
