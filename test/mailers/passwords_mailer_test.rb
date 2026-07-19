require "test_helper"

class PasswordsMailerTest < ActionMailer::TestCase
  test "reset is a branded multipart email with an expiring action" do
    designer = designers(:one)
    mail = PasswordsMailer.reset(designer)

    assert_equal [ designer.email_address ], mail.to
    configured_from = Mail::Address.new(ENV.fetch("MAIL_FROM", "Printwright <no-reply@printwright.local>")).address
    assert_equal [ configured_from ], mail.from
    assert_equal "Reset your Printwright password", mail.subject
    assert_equal %w[text/plain text/html], mail.parts.map { |part| part.content_type.split(";").first }

    html = mail.html_part.decoded
    text = mail.text_part.decoded
    assert_includes html, "Printwright"
    assert_includes html, "Reset password"
    assert_match %r{/passwords/[^/]+/edit}, html
    assert_includes html, "one-time link"
    assert_includes text, "Printwright"
    assert_match %r{/passwords/[^/]+/edit}, text
    assert_includes text, "If you did not request"
  end
end
