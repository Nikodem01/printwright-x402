# One immutable row per revenue split leg. Written exactly once per settled
# purchase (via Purchase#transition_to!, the single status funnel); rows are
# never updated or deleted — corrections are new entries (refunds, later).
class LedgerEntry < ApplicationRecord
  PLATFORM_FEE_BPS = 1_000 # 10% MVP default, PRODUCT §10

  KINDS = %w[designer_share platform_fee designer_payout].freeze

  # designer_share still held in treasury custody and not yet covered by a
  # designer_payout row for the same purchase. The unique
  # [purchase_id, entry_kind] index makes double-payout structurally impossible.
  scope :owed, -> {
    where(entry_kind: "designer_share", held_by: "treasury")
      .where.not(purchase_id: where(entry_kind: "designer_payout").select(:purchase_id))
  }

  belongs_to :purchase
  belongs_to :designer, optional: true

  validates :entry_kind, inclusion: { in: KINDS }
  validates :held_by, inclusion: { in: %w[treasury designer] }
  validates :asset, presence: true
  validates :amount_base_units,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  def readonly? = persisted?

  # Splits the settled amount 90/10 (fee floor-rounded, so odd base units
  # favor the designer). Idempotent: replays and mirror reconciliations may
  # cross the settled transition more than once.
  #
  # held_by records where the money physically landed (single-recipient
  # settles — the facilitator rejects multi-leg): payTo=treasury means the
  # designer_share is owed out; payTo=designer means the platform_fee is a
  # receivable held by the designer.
  def self.record_settle!(purchase)
    return if exists?(purchase: purchase)

    gross = Integer(purchase.amount_base_units)
    fee = gross * PLATFORM_FEE_BPS / 10_000
    designer = purchase.model3d.designer
    pay_to = purchase.requirements_json["payTo"]
    landed_with_designer = pay_to.present? &&
      pay_to == designer.hedera_account_id &&
      pay_to != ENV["X402_PAY_TO"] # treasury is treasury, whoever claims its id
    held_by = landed_with_designer ? "designer" : "treasury"
    # requires_new: a savepoint, so losing the duplicate race (rescued below)
    # can't poison the caller's transaction (transition_to! wraps this).
    transaction(requires_new: true) do
      create!(purchase: purchase, entry_kind: "platform_fee",
        asset: purchase.asset, amount_base_units: fee, held_by: held_by)
      create!(purchase: purchase, entry_kind: "designer_share", designer: designer,
        asset: purchase.asset, amount_base_units: gross - fee, held_by: held_by)
    end
  rescue ActiveRecord::RecordNotUnique
    nil # concurrent writer got there first — entries exist, which is the goal
  end
end
