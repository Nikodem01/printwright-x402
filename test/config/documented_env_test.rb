require "test_helper"

# An operator can only turn on what the sample env file mentions. Social sign-in
# was implemented, offered in the UI when configured, and named nowhere in
# .env.example — so the feature existed but could not be enabled from the
# documentation.
#
# Now that config/printwright.yml is the one place the app reads ENV, that file
# is the complete list of what can be configured, and this compares it against
# the documentation rather than restating either. A setting added to the app
# without a line in .env.example fails here, whatever it configures.
class DocumentedEnvTest < ActiveSupport::TestCase
  # Matches both `NAME=` and the commented `# NAME=` form the file uses for
  # optional settings.
  def documented
    Rails.root.join(".env.example").read.scan(/^#?\s*([A-Z][A-Z0-9_]+)=/).flatten.uniq
  end

  def env_names_in(path)
    Rails.root.join(path).read.scan(/ENV(?:\.fetch)?[\[(]\s*"([A-Z][A-Z0-9_]+)"/).flatten.uniq
  end

  test "every setting the app can read is named in .env.example" do
    configurable = env_names_in("config/printwright.yml")

    assert_operator configurable.size, :>=, 20,
      "expected config/printwright.yml to be the app's whole ENV surface, found #{configurable.inspect}"

    missing = configurable - documented
    assert_empty missing,
      "#{missing.join(', ')} can be set in config/printwright.yml but is absent from .env.example, " \
      "so an operator cannot discover the setting they control"
  end

  test "the sign-in provider credentials are configurable and documented" do
    credentials = env_names_in("config/printwright.yml").grep(/_CLIENT_(ID|SECRET)\z/)

    assert_equal %w[GITHUB_CLIENT_ID GITHUB_CLIENT_SECRET GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET],
      credentials.sort
    assert_empty credentials - documented,
      "a sign-in button is gated on a variable .env.example never mentions"
  end

  test "application code reads configuration, never ENV directly" do
    offenders = Dir[Rails.root.join("app/**/*.rb"), Rails.root.join("app/**/*.erb")].filter_map do |path|
      lines = File.readlines(path).each_with_index.select do |line, _|
        line.match?(/ENV(?:\.fetch)?[\[(]\s*"/) && !line.include?('ENV["DISPLAY"]')
      end
      next if lines.empty?
      "#{Pathname.new(path).relative_path_from(Rails.root)}:#{lines.map { |_, i| i + 1 }.join(',')}"
    end

    # DISPLAY is the one exception: it is ambient process state ("is there an X
    # server?"), not a setting anyone deploys.
    assert_empty offenders,
      "these read ENV instead of Rails.configuration.x.printwright: #{offenders.join(' ')}"
  end
end
