# Tier 2 of the configuration pipeline: config/printwright.yml collects the raw
# values, PrintwrightSettings types them, and everything after this treats
# Rails.configuration.x.printwright as read-only.
#
# Required rather than autoloaded: this runs before the autoloaders are ready,
# and configuration must not depend on reloadable code anyway.
require_relative "../printwright_settings"

config = PrintwrightSettings.normalize!(Rails.configuration.x.printwright)

# Production must not start on a demo default, and must not start missing a
# secret. Discovering either from a 500 — or worse, from a payment landing in
# someone else's treasury — is not a thing to find out in production.
if Rails.env.production? && !ENV["SECRET_KEY_BASE_DUMMY"]
  required_env = %w[
    APP_HOST S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY S3_BUCKET
    SMTP_ADDRESS SMTP_USERNAME SMTP_PASSWORD HEDERA_ACCOUNT_ID
  ]
  missing = required_env.select { |name| ENV[name].blank? }
  raise "Missing production configuration: #{missing.join(', ')}" if missing.any?

  blank = PrintwrightSettings.missing_in_production(config)
  raise "Missing production configuration: #{blank.join(', ')}" if blank.any?

  if config.sidecar_token == "change-me"
    raise "SIDECAR_TOKEN is still the .env.example placeholder — set a real shared secret"
  end

  ttl = Integer(ENV.fetch("STORAGE_URL_TTL_MINUTES", "10"), exception: false)
  raise "STORAGE_URL_TTL_MINUTES must be between 1 and 60" unless ttl in 1..60
end
