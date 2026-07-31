# Typing and validation for config/printwright.yml.
#
# The YAML collects raw strings from ENV; this turns them into the types the
# application expects, once, at boot. It lives here rather than inside the
# initializer so the rules that decide "how much may chat spend?" can be tested
# directly instead of only through the app that consumes them.
module PrintwrightSettings
  # Values that mean "unset" when blank, rather than "empty string".
  OPTIONAL = %i[
    mirror_node_url sidecar_token x402_pay_to demo_hbar_price_cents
    walletconnect_project_id demo_wallet_url gemini_api_key
    github_client_id github_client_secret google_client_id google_client_secret
    chat_daily_visitor_message_limit chat_daily_provider_call_limit
    backup_s3_bucket s3_endpoint s3_access_key_id s3_secret_access_key
  ].freeze

  # Everything production refuses to start without. A demo default reaching
  # production is as bad as a missing value: worse for x402_pay_to, where it
  # would send real money to someone else's treasury.
  REQUIRED_IN_PRODUCTION = %i[
    hedera_network hcs_topic_id mirror_node_url sidecar_url sidecar_token
    x402_pay_to x402_facilitator_url walletconnect_project_id
  ].freeze

  # Caps on what one account, and the deployment as a whole, may store.
  STORAGE_LIMITS = %i[
    storage_bytes_per_designer storage_bytes_global
    max_models_per_designer max_files_per_model
  ].freeze

  module_function

  def normalize!(config)
    config.chat_purchases_enabled = config.chat_purchases_enabled.to_s == "true"
    config.chat_max_spend_cents = integer_or_zero(config.chat_max_spend_cents)
    config.chat_daily_spend_cents =
      if config[:chat_daily_spend_cents].present?
        integer_or_zero(config.chat_daily_spend_cents)
      else
        config.chat_max_spend_cents
      end
    config.s3_force_path_style = config.s3_force_path_style.to_s == "true"
    # Same fail-closed rule as the spend caps, for the same reason: a typo in a
    # storage cap must never be read as "no limit". Here 0 means every upload
    # is refused with a clear message, which is recoverable — whereas an
    # unbounded cap fills the disk the whole host shares.
    STORAGE_LIMITS.each { |key| config[key] = integer_or_zero(config[key]) }
    # Retention is fail-safe rather than fail-closed, the opposite of the caps
    # above: 0 kept dumps would mean deleting the backup you just took.
    config.backup_disk_keep = [ integer_or_zero(config.backup_disk_keep), 1 ].max
    OPTIONAL.each { |key| config[key] = config[key].presence }
    config
  end

  # Spend caps are fail-closed: anything that is not a plain non-negative
  # integer becomes 0, which turns buying off. A typo in a cap must never be
  # read as "no limit", and must not be silently rounded into a number either.
  def integer_or_zero(value)
    string = value.to_s
    string.match?(/\A\d+\z/) ? string.to_i : 0
  end

  def missing_in_production(config)
    REQUIRED_IN_PRODUCTION.select { |key| config[key].blank? }
  end
end
