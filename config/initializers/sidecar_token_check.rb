# The sidecar bearer token gates real key-holder operations. A missing or
# placeholder token in production is a misconfiguration worth refusing to
# boot over — not worth discovering from a 401 mid-demo.
if Rails.env.production?
  token = ENV["SIDECAR_TOKEN"].to_s
  if token.blank? || token == "change-me"
    raise "SIDECAR_TOKEN is unset or still the .env.example placeholder — set a real shared secret"
  end
end
