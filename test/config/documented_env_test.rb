require "test_helper"

# An operator can only turn on what the sample env file mentions. Social sign-in
# was implemented, offered in the UI when configured, and named nowhere in
# .env.example — so the feature existed but could not be enabled from the
# documentation. Derive the list from the configuration itself rather than
# restating it, so a fifth provider variable cannot be added silently.
class DocumentedEnvTest < ActiveSupport::TestCase
  # Matches both `NAME=` and the commented `# NAME=` form the file uses for
  # optional settings.
  def documented
    Rails.root.join(".env.example").read.scan(/^#?\s*([A-Z][A-Z0-9_]+)=/).flatten.uniq
  end

  def env_vars_read_in(path)
    Rails.root.join(path).read.scan(/ENV\["([A-Z0-9_]+)"\]/).flatten.uniq
  end

  test "every provider credential Rodauth reads is named in .env.example" do
    credentials = env_vars_read_in("app/misc/rodauth_main.rb").grep(/_CLIENT_(ID|SECRET)\z/)

    assert_operator credentials.size, :>=, 4,
      "expected the GitHub and Google client id/secret pairs, found #{credentials.inspect}"

    missing = credentials - documented
    assert_empty missing,
      "#{missing.join(', ')} read by rodauth_main.rb but absent from .env.example, " \
      "so an operator cannot enable the sign-in method they control"
  end

  test "the sign-in buttons and .env.example agree on which variables gate them" do
    gating = env_vars_read_in("app/views/rodauth/_omniauth.html.erb")

    assert_equal %w[GITHUB_CLIENT_ID GOOGLE_CLIENT_ID], gating.sort
    assert_empty gating - documented,
      "a button is gated on a variable .env.example never mentions"
  end
end
