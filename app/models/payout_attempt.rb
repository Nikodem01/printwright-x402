# Mutable operational state around an immutable designer payout. One row follows
# one owed purchase share through retries; the ledger remains the financial truth.
class PayoutAttempt < ApplicationRecord
  STATUSES = %w[processing retrying failed reconciliation_required succeeded].freeze
  RETRYABLE_ERROR_CODES = %w[service_unavailable not_submitted].freeze
  UNRESOLVED_STATUSES = %w[processing retrying failed reconciliation_required].freeze

  belongs_to :designer
  belongs_to :purchase

  scope :unresolved, -> { where(status: UNRESOLVED_STATUSES) }

  validates :ref, :asset, presence: true
  validates :ref, length: { maximum: 100 }
  validates :status, inclusion: { in: STATUSES }
  validates :attempt_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :purchase_id, uniqueness: true
  validate :purchase_belongs_to_designer

  def retryable?
    status == "failed" && last_error_code.in?(RETRYABLE_ERROR_CODES)
  end

  def self.start!(entries:, ref:)
    now = Time.current
    entries.map do |entry|
      attempt = find_or_initialize_by(purchase: entry.purchase)
      attempt.assign_attributes(
        designer: entry.designer, ref: ref, asset: entry.asset,
        status: "processing", attempt_count: attempt.attempt_count + 1,
        last_error_code: nil, tx_id: nil, last_attempted_at: now, completed_at: nil
      )
      attempt.save!
      attempt
    end
  end

  def self.succeed!(entries:, tx_id:)
    now = Time.current
    where(purchase_id: entries.map(&:purchase_id)).update_all(
      status: "succeeded", last_error_code: nil, tx_id: tx_id,
      completed_at: now, updated_at: now
    )
  end

  def self.fail_entries!(entries:, status:, error_code:, tx_id: nil)
    now = Time.current
    where(purchase_id: entries.map(&:purchase_id)).update_all(
      status: status, last_error_code: error_code, tx_id: tx_id,
      completed_at: nil, updated_at: now
    )
  end

  def self.fail_remaining!(ref:, status:, error_code:)
    now = Time.current
    where(ref: ref, status: "processing").update_all(
      status: status, last_error_code: error_code, completed_at: nil, updated_at: now
    )
  end

  def self.exhaust!(ref:)
    now = Time.current
    where(ref: ref, status: "retrying").update_all(
      status: "failed", last_error_code: "service_unavailable", updated_at: now
    )
  end

  def self.reconcile_ref!(ref:, designer: nil)
    scope = unresolved.where(ref: ref)
    scope = scope.where(designer: designer) if designer
    scope.find_each do |attempt|
      payout = LedgerEntry.find_by(purchase: attempt.purchase, entry_kind: "designer_payout")
      if payout
        attempt.update!(status: "succeeded", last_error_code: nil, tx_id: payout.tx_id,
          completed_at: payout.created_at)
      elsif !attempt.designer.payout_account_verified?
        attempt.update!(status: "failed", last_error_code: "destination_not_ready")
      end
    end
  end

  private

  def purchase_belongs_to_designer
    return unless purchase && designer
    return if purchase.model3d.designer_id == designer_id

    errors.add(:purchase, "must belong to the same designer")
  end
end
