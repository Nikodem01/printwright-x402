require "rotp"

module SessionTestHelper
  # Authenticate through the Rodauth login route so integration tests exercise the
  # real session cookie. Fixture designers are `verified` with password "password".
  # Admins must have 2FA (Admin::BaseController), so enroll + pass the second factor
  # by driving Rodauth's real otp-setup flow.
  def sign_in_as(designer, password: "password")
    post "/login", params: { email: designer.email_address, password: password }
    complete_two_factor_setup(password) if designer.admin?
    designer
  end

  def sign_out
    post "/logout"
  end

  private

  def complete_two_factor_setup(password)
    get "/otp-setup"
    return unless response.ok? # already enrolled — login handled the second factor

    form = Nokogiri::HTML(response.body)
    secret_field = form.at_css("#otp-key")
    params = {
      secret_field["name"] => secret_field["value"],
      "otp" => ROTP::TOTP.new(secret_field["value"]).now,
      "password" => password
    }
    if (raw = form.at_css("#otp-hmac-secret"))
      params[raw["name"]] = raw["value"]
    end
    post "/otp-setup", params: params
  end
end

ActiveSupport.on_load(:action_dispatch_integration_test) do
  include SessionTestHelper
end
