# Be sure to restart your server when you modify this file.

# Nonce-based CSP. Notes that keep the demo alive:
# - style-src allows inline styles (views use style attributes heavily);
#   scripts are nonce-only — no inline handlers anywhere (grep before adding).
# - WalletConnect sources follow Reown's published CSP guidance. The browser
#   module is local and lazy; only its relay/modal data crosses these origins.
# - The V3 spike page in public/ is served statically and bypasses this
#   middleware by design.
Rails.application.configure do
  config.content_security_policy do |policy|
    wallet_connect = %w[
      https://rpc.walletconnect.com https://rpc.walletconnect.org
      https://relay.walletconnect.com https://relay.walletconnect.org
      wss://relay.walletconnect.com wss://relay.walletconnect.org
      https://pulse.walletconnect.com https://pulse.walletconnect.org
      https://api.web3modal.com https://api.web3modal.org
      https://keys.walletconnect.com https://keys.walletconnect.org
      https://explorer-api.walletconnect.com
    ]
    connect_sources = [ :self, *wallet_connect ]
    connect_sources << ENV["DEMO_WALLET_URL"] if ENV["DEMO_WALLET_URL"].present?
    policy.default_src :self
    policy.font_src    :self, "https://fonts.reown.com"
    policy.img_src     :self, :data, :blob,
                       "https://walletconnect.com", "https://walletconnect.org",
                       "https://secure.walletconnect.com", "https://secure.walletconnect.org",
                       "https://explorer-api.walletconnect.com"
    policy.object_src  :none
    policy.script_src  :self
    policy.style_src   :self, :unsafe_inline
    policy.connect_src(*connect_sources)
    policy.frame_src   :self, "https://verify.walletconnect.com", "https://verify.walletconnect.org",
                       "https://secure.walletconnect.com", "https://secure.walletconnect.org"
    policy.frame_ancestors :none
    policy.base_uri :self
  end

  config.content_security_policy_nonce_generator =
    ->(request) { request.session.id.to_s.presence || SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]
end
