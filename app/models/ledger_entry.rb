# One immutable row per revenue split leg. Written exactly once per settled
# purchase (via Purchase#transition_to!, the single status funnel); rows are
# never updated or deleted — corrections are new entries (refunds, later).
class LedgerEntry < ApplicationRecord
  PLATFORM_FEE_BPS = 1_000 # 10% MVP default, PRODUCT §10

  KINDS = %w[designer_share platform_fee].freeze

  belongs_to :purchase
  belongs_to :designer, optional: true

  validates :entry_kind, inclusion: { in: KINDS }
  validates :asset, presence: true
  validates :amount_base_units,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  def readonly? = persisted?

  # Splits the settled amount 90/10 (fee floor-rounded, so odd base units
  # favor the designer). Idempotent: replays and mirror reconciliations may
  # cross the settled transition more than once.
  def self.record_settle!(purchase)
    return if exists?(purchase: purchase)

    gross = Integer(purchase.amount_base_units)
    fee = gross * PLATFORM_FEE_BPS / 10_000
    # requires_new: a savepoint, so losing the duplicate race (rescued below)
    # can't poison the caller's transaction (transition_to! wraps this).
    transaction(requires_new: true) do
      create!(purchase: purchase, entry_kind: "platform_fee",
        asset: purchase.asset, amount_base_units: fee)
      create!(purchase: purchase, entry_kind: "designer_share",
        designer: purchase.model3d.designer,
        asset: purchase.asset, amount_base_units: gross - fee)
    end
  rescue ActiveRecord::RecordNotUnique
    nil # concurrent writer got there first — entries exist, which is the goal
  end
end
