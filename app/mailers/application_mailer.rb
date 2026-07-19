class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAIL_FROM", "Printwright <no-reply@printwright.local>")
  layout "mailer"
end
