class ApplicationMailer < ActionMailer::Base
  default from: -> { Rails.configuration.x.printwright.mail_from }
  layout "mailer"
end
