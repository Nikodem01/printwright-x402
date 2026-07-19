class Designer < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :models3d, class_name: "Model3d", dependent: :destroy
  has_many :admin_audit_logs, foreign_key: :actor_designer_id

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :display_name, presence: true

  # A changed payout account is unverified until the mirror check passes again.
  before_save -> { self.payout_account_verified_at = nil }, if: :hedera_account_id_changed?

  def payout_account_verified?
    hedera_account_id.present? && payout_account_verified_at.present?
  end

  # Runs the mirror check and stamps the result. Returns the verified? state.
  def verify_payout_account!
    ok = Designers::PayoutAccountCheck.call(hedera_account_id)
    update!(payout_account_verified_at: ok ? Time.current : nil)
    ok
  end
end
