if Rails.env.production? && !ENV["SECRET_KEY_BASE_DUMMY"]
  required = %w[
    APP_HOST MAIL_FROM WALLETCONNECT_PROJECT_ID S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY S3_BUCKET
    SMTP_ADDRESS SMTP_USERNAME SMTP_PASSWORD
    HEDERA_NETWORK HEDERA_ACCOUNT_ID HEDERA_HCS_TOPIC_ID HEDERA_HEARTBEAT_TOPIC_ID
    HEDERA_SIDECAR_URL X402_FACILITATOR_URL X402_PAY_TO MIRROR_NODE_URL
  ]
  missing = required.select { |name| ENV[name].blank? }
  raise "Missing production configuration: #{missing.join(', ')}" if missing.any?

  ttl = Integer(ENV.fetch("STORAGE_URL_TTL_MINUTES", "10"), exception: false)
  raise "STORAGE_URL_TTL_MINUTES must be between 1 and 60" unless ttl in 1..60
end
