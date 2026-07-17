# The designer statement: every sale as its ledger share row, with where the
# money is right now (paid direct / paid out / owed / refunded) and running
# owed balances. Rows come from the immutable ledger, not from purchases —
# what the designer sees is exactly what the books say.
class Designer::SalesController < Designer::BaseController
  def index
    @shares = LedgerEntry.where(designer: current_designer, entry_kind: "designer_share")
                         .includes(purchase: [ :license, { license_offer: :model3d } ])
                         .order(created_at: :desc)
    related = LedgerEntry.where(purchase_id: @shares.map(&:purchase_id))
    @payouts = related.where(entry_kind: "designer_payout").index_by(&:purchase_id)
    @refunds = related.where(entry_kind: "refund").index_by(&:purchase_id)
    @owed = LedgerEntry.owed.where(designer: current_designer).group(:asset).sum(:amount_base_units)
  end
end
