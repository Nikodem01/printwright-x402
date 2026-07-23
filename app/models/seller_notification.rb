# A durable in-product notice for a designer: one row per seller-visible
# event (sale, cert, payout, destination change, webhook exhaustion, mesh
# analysis, identity check). Never carries buyer identity — the payload is
# capped to a small allow-list of seller-operational facts per kind, so a
# stray key (buyer_hint, email, session, receipt token, payment payload)
# never becomes designer-visible even if a call site passes one by mistake.
class SellerNotification < ApplicationRecord
  KINDS = %w[
    sale_delivered certificate_anchored
    payout_completed payout_failed payout_reconciliation_required
    payout_destination_staged payout_destination_hold
    payout_destination_activated payout_destination_cancelled
    webhook_delivery_failed
    mesh_analysis_passed mesh_analysis_failed
    identity_verification_passed identity_verification_failed
  ].freeze

  PERMITTED_PAYLOAD_KEYS = {
    "sale_delivered" => %w[license_type asset amount_base_units serial],
    "certificate_anchored" => %w[cert_id hcs_sequence_number],
    "payout_completed" => %w[asset amount_base_units tx_id ref],
    "payout_failed" => %w[asset amount_base_units error_code ref],
    "payout_reconciliation_required" => %w[asset amount_base_units tx_id error_code ref],
    "payout_destination_staged" => %w[hedera_account_id],
    "payout_destination_hold" => %w[hedera_account_id hold_until],
    "payout_destination_activated" => %w[hedera_account_id],
    "payout_destination_cancelled" => %w[hedera_account_id],
    "webhook_delivery_failed" => %w[url event_type last_error],
    "mesh_analysis_passed" => %w[],
    "mesh_analysis_failed" => %w[errors],
    "identity_verification_passed" => %w[profile_url host],
    "identity_verification_failed" => %w[profile_url host reason]
  }.freeze

  belongs_to :designer
  belongs_to :model3d, optional: true

  validates :kind, inclusion: { in: KINDS }

  scope :unread, -> { where(read_at: nil) }
  scope :recent, -> { order(created_at: :desc) }

  def unread? = read_at.nil?

  # The only write path: strips any payload key not on the kind's allow-list
  # before the row is ever created, so an unknown kind's inclusion validation
  # (not the strip) is what surfaces a coding mistake.
  def self.record!(designer:, kind:, model3d: nil, payload: {})
    permitted = PERMITTED_PAYLOAD_KEYS.fetch(kind.to_s, [])
    safe_payload = payload.to_h.stringify_keys.slice(*permitted)
    create!(designer: designer, kind: kind, model3d: model3d, payload: safe_payload)
  end
end
