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

    def self.call(dry_run: false)
      return run(dry_run: true) if dry_run

      LedgerEntry.transaction do
        LedgerEntry.connection.execute("SELECT pg_advisory_xact_lock(#{ADVISORY_LOCK_KEY})")
        run(dry_run: false)
      end
    end

    def self.run(dry_run:)
      eligible = LedgerEntry.owed.includes(:designer, :purchase)
        .select { |e| e.designer&.payout_account_verified? }

      eligible.group_by(&:asset).filter_map do |asset, entries|
        transfers = entries.group_by(&:designer).map do |designer, owed|
          { accountId: designer.hedera_account_id,
            amount: owed.sum { |e| Integer(e.amount_base_units) }.to_s }
        end
        next Payout.new(asset: asset, tx_id: nil, transfers: transfers) if dry_run

        response = SidecarClient.new.payout(
          token_id: asset, transfers: transfers,
          memo: "printwright designer payout #{Time.current.strftime('%Y-%m-%d')}"
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
  end
end
