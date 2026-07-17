# Be sure to restart your server when you modify this file.

# Nonce-based CSP. Notes that keep the demo alive:
# - style-src allows inline styles (views use style attributes heavily);
#   scripts are nonce-only — no inline handlers anywhere (grep before adding).
# - connect-src includes the wallet-lite demo signer (localhost daemon).
#   V25 (HashPack) must add the WalletConnect relay wss origin here.
# - The V3 spike page in public/ is served statically and bypasses this
#   middleware by design.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self
    policy.img_src     :self, :data
    policy.object_src  :none
    policy.script_src  :self
    policy.style_src   :self, :unsafe_inline
    policy.connect_src :self, ENV.fetch("DEMO_WALLET_URL", "http://localhost:4022")
    policy.frame_ancestors :none
    policy.base_uri    :self
  end

  config.content_security_policy_nonce_generator =
    ->(request) { request.session.id.to_s.presence || SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]
end
