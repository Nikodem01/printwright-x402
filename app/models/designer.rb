class Designer < ApplicationRecord
  include Rodauth::Rails.model

  # Rodauth account status. Prefixed so it never collides with the existing
  # identity-badge `verified` boolean (`verified?`).
  enum :status, { unverified: 1, verified: 2, closed: 3 }, prefix: :account

  has_many :models3d, class_name: "Model3d", dependent: :destroy
  has_many :catalog_imports, dependent: :destroy
  has_many :profile_verifications, dependent: :destroy
  has_many :webhook_endpoints, dependent: :destroy
  has_many :payout_attempts, dependent: :destroy
  has_many :seller_notifications, dependent: :destroy
  has_many :admin_audit_logs, foreign_key: :actor_designer_id

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :display_name, presence: true

  # Direct/legacy writes can never carry verification to a different destination.
  before_save :reset_payout_verification, if: :hedera_account_id_changed?

  # Email ownership proven via Rodauth verify_account (gates publish + payout, S2).
  def email_verified?
    account_verified?
  end

  def payout_account_verified?
    hedera_account_id.present? && payout_account_verified_at.present?
  end

  def payout_destination_change_pending?
    payout_pending_account_id.present?
  end

  def payout_destination_state
    return :safety_hold if payout_proof_verified_at.present? && payout_hold_until&.future?
    return :ready_to_activate if payout_proof_verified_at.present?
    return :awaiting_proof if payout_destination_change_pending?
    return :active if payout_account_verified?
    return :needs_proof if hedera_account_id.present?

    :not_set
  end

  def identity_verified?
    identity_verified_at.present? && verified_profile_url.present?
  end

  # Rechecks a destination that is already active. Establishing control of a
  # new destination is exclusively the signed proof flow in Payouts.
  def verify_payout_account!
    return false unless payout_account_verified?

    ok = Designers::PayoutAccountCheck.call(hedera_account_id)
    update!(payout_account_verified_at: ok ? Time.current : nil)
    ok
  end

  private

  def reset_payout_verification
    self.payout_account_verified_at = nil
    self.payout_account_control_verified_at = nil
  end
end
