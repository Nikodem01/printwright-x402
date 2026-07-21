class Designer < ApplicationRecord
  include Rodauth::Rails.model

  # Rodauth account status. Prefixed so it never collides with the existing
  # identity-badge `verified` boolean (`verified?`).
  enum :status, { unverified: 1, verified: 2, closed: 3 }, prefix: :account

  has_many :models3d, class_name: "Model3d", dependent: :destroy
  has_many :catalog_imports, dependent: :destroy
  has_many :profile_verifications, dependent: :destroy
  has_many :webhook_endpoints, dependent: :destroy
  has_many :admin_audit_logs, foreign_key: :actor_designer_id

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :display_name, presence: true

  # A changed payout account is unverified until the mirror check passes again.
  before_save -> { self.payout_account_verified_at = nil }, if: :hedera_account_id_changed?

  # Email ownership proven via Rodauth verify_account (gates publish + payout, S2).
  def email_verified?
    account_verified?
  end

  def payout_account_verified?
    hedera_account_id.present? && payout_account_verified_at.present?
  end

  def identity_verified?
    identity_verified_at.present? && verified_profile_url.present?
  end

  # Runs the mirror check and stamps the result. Returns the verified? state.
  def verify_payout_account!
    ok = Designers::PayoutAccountCheck.call(hedera_account_id)
    update!(payout_account_verified_at: ok ? Time.current : nil)
    ok
  end
end
