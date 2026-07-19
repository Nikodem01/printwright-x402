if Rails.env.production? && !ENV["SECRET_KEY_BASE_DUMMY"]
  required = %w[S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY S3_BUCKET]
  missing = required.select { |name| ENV[name].blank? }
  raise "Missing production configuration: #{missing.join(', ')}" if missing.any?

  ttl = Integer(ENV.fetch("STORAGE_URL_TTL_MINUTES", "10"), exception: false)
  raise "STORAGE_URL_TTL_MINUTES must be between 1 and 60" unless ttl in 1..60
end
