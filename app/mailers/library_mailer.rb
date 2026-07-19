class LibraryMailer < ApplicationMailer
  def access(email_address)
    @token = LibraryMembership.access_token(email_address)
    mail subject: "Your Printwright license library", to: email_address
  end
end
