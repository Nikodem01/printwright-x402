module Ledger
  # Pays designers their owed (treasury-custody) shares: one batched on-chain
  # transfer per asset via the sidecar, then a designer_payout ledger row per
  # covered purchase carrying the tx id. Only designers whose payout account
  # passed the mirror check get paid; the rest stay owed.
  #
  # Failure honesty: entries are written immediately after each asset's
  # transfer settles. A crash between the sidecar call and the write would
  # leave that one asset unrecorded — reconcile against HashScan (the memo
  # names the run) before re-running. See docs/OPERATIONS.md (V8).
  class PayoutRunner
    Payout = Struct.new(:asset, :tx_id, :transfers, keyword_init: true)

    ADVISORY_LOCK_KEY = 420_201 # serializes payout runs — two at once = double pay

    # purchase_ids scopes the run to one checkout (the immediate per-checkout
    # payout); nil sweeps everything owed (the admin/scheduled backstop). ref
    # names the run in the on-chain memo so an immediate payout reconciles to
    # its checkout.
    def self.call(dry_run: false, purchase_ids: nil, ref: nil)
      return run(dry_run: true, purchase_ids: purchase_ids, ref: ref) if dry_run

      LedgerEntry.transaction do
        LedgerEntry.connection.execute("SELECT pg_advisory_xact_lock(#{ADVISORY_LOCK_KEY})")
        run(dry_run: false, purchase_ids: purchase_ids, ref: ref)
      end
    end

    def self.run(dry_run:, purchase_ids: nil, ref: nil)
      scope = LedgerEntry.owed.includes(:designer, :purchase)
      scope = scope.where(purchase_id: purchase_ids) if purchase_ids
      eligible = scope.select { |e| e.designer&.payout_account_verified? }

      eligible.group_by(&:asset).filter_map do |asset, entries|
        transfers = entries.group_by(&:designer).map do |designer, owed|
          { accountId: designer.hedera_account_id,
            amount: owed.sum { |e| Integer(e.amount_base_units) }.to_s }
        end
        next Payout.new(asset: asset, tx_id: nil, transfers: transfers) if dry_run

        response = SidecarClient.new.payout(
          token_id: asset, transfers: transfers,
          memo: payout_memo(ref)
        )
        tx_id = response.fetch("transactionId")
        LedgerEntry.transaction do
          entries.each do |entry|
            LedgerEntry.create!(
              purchase: entry.purchase, designer: entry.designer,
              entry_kind: "designer_payout", asset: asset,
              amount_base_units: entry.amount_base_units,
              held_by: "designer", tx_id: tx_id
            )
          end
        end
        Payout.new(asset: asset, tx_id: tx_id, transfers: transfers)
      end
    end

    # Immediate per-checkout payouts carry their checkout ref (reconcilable to a
    # single purchase/batch); the backstop keeps the dated memo the runbook names.
    def self.payout_memo(ref)
      return "printwright payout #{ref}" if ref
      "printwright designer payout #{Time.current.strftime('%Y-%m-%d')}"
    end
  end
end
