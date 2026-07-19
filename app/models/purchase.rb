# Purchase lifecycle is forward-only; `settled` is the point of no return
# (money moved on-chain) — everything after must be retryable, never rolled
# back. Change status ONLY via transition_to! so the guard always applies.
class Purchase < ApplicationRecord
  class InvalidTransition < StandardError; end

  TRANSITIONS = {
    "pending"             => %w[verified failed_verification],
    "verified"            => %w[settled failed_settlement],
    "settled"             => %w[delivered refunded],
    "delivered"           => [],
    "refunded"            => [],
    "failed_verification" => [],
    "failed_settlement"   => []
  }.freeze

  belongs_to :license_offer
  has_one :license, dependent: :destroy
  has_one :model3d, through: :license_offer

  enum :status, TRANSITIONS.keys.index_by(&:itself), default: "pending"

  validates :replay_key, presence: true, uniqueness: true

  def transition_to!(new_status)
    new_status = new_status.to_s
    unless TRANSITIONS.fetch(status).include?(new_status)
      raise InvalidTransition, "cannot transition #{status} -> #{new_status}"
    end
    transaction do
      update!(status: new_status)
      # settled = money moved; the revenue split is recorded in the same
      # transaction so no settled purchase can exist without ledger rows.
      LedgerEntry.record_settle!(self) if new_status == "settled" && !sandbox?
    end
  end
end
