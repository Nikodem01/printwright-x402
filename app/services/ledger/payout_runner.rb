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
    def self.call(dry_run: false, purchase_ids: nil, ref: nil, automatic_retry: false)
      return run(dry_run: true, purchase_ids: purchase_ids, ref: ref) if dry_run

      with_advisory_lock do
        attempt_ref = ref.presence || "sweep-#{SecureRandom.uuid}"
        run(dry_run: false, purchase_ids: purchase_ids, ref: ref,
          attempt_ref: attempt_ref, automatic_retry: automatic_retry)
      end
    end

    def self.run(dry_run:, purchase_ids: nil, ref: nil, attempt_ref: nil, automatic_retry: false)
      scope = LedgerEntry.owed.includes(:designer, :purchase)
      scope = scope.where(purchase_id: purchase_ids) if purchase_ids
      scope = scope.where.not(
        purchase_id: PayoutAttempt.where(status: "reconciliation_required").select(:purchase_id)
      )
      eligible = scope.select { |e| e.designer&.payout_account_verified? }
      PayoutAttempt.start!(entries: eligible, ref: attempt_ref) unless dry_run

      eligible.group_by(&:asset).filter_map do |asset, entries|
        transfers = entries.group_by(&:designer).map do |designer, owed|
          { accountId: designer.hedera_account_id,
            amount: owed.sum { |e| Integer(e.amount_base_units) }.to_s }
        end
        next Payout.new(asset: asset, tx_id: nil, transfers: transfers) if dry_run

        tx_id = nil
        begin
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
            PayoutAttempt.succeed!(entries: entries, tx_id: tx_id)
          end
          notify_payout_state(entries, kind: "payout_completed", asset: asset, tx_id: tx_id, ref: attempt_ref)
        rescue SidecarClient::Unavailable
          status = automatic_retry ? "retrying" : "failed"
          PayoutAttempt.fail_remaining!(ref: attempt_ref, status: status,
            error_code: "service_unavailable")
          if status == "failed"
            notify_payout_state(entries, kind: "payout_failed", asset: asset,
              error_code: "service_unavailable", ref: attempt_ref)
          end
          raise
        rescue SidecarClient::Ambiguous
          PayoutAttempt.fail_entries!(entries: entries, status: "reconciliation_required",
            error_code: "ambiguous_result", tx_id: tx_id)
          PayoutAttempt.fail_remaining!(ref: attempt_ref, status: "failed",
            error_code: "not_submitted")
          notify_payout_state(entries, kind: "payout_reconciliation_required", asset: asset,
            tx_id: tx_id, error_code: "ambiguous_result", ref: attempt_ref)
          raise
        rescue SidecarClient::Rejected
          PayoutAttempt.fail_entries!(entries: entries, status: "failed",
            error_code: "transfer_rejected")
          PayoutAttempt.fail_remaining!(ref: attempt_ref, status: "failed",
            error_code: "not_submitted")
          notify_payout_state(entries, kind: "payout_failed", asset: asset,
            error_code: "transfer_rejected", ref: attempt_ref)
          raise
        rescue StandardError
          if tx_id
            PayoutAttempt.fail_entries!(entries: entries, status: "reconciliation_required",
              error_code: "ledger_recording_failed", tx_id: tx_id)
            notify_payout_state(entries, kind: "payout_reconciliation_required", asset: asset,
              tx_id: tx_id, error_code: "ledger_recording_failed", ref: attempt_ref)
          end
          raise
        end
        Payout.new(asset: asset, tx_id: tx_id, transfers: transfers)
      end.tap { PayoutAttempt.reconcile_ref!(ref: attempt_ref) unless dry_run }
    end

    def self.with_advisory_lock
      connection = LedgerEntry.connection
      locked = false
      connection.execute("SELECT pg_advisory_lock(#{ADVISORY_LOCK_KEY})")
      locked = true
      yield
    ensure
      connection&.execute("SELECT pg_advisory_unlock(#{ADVISORY_LOCK_KEY})") if locked
    end

    # Immediate per-checkout payouts carry their checkout ref (reconcilable to a
    # single purchase/batch); the backstop keeps the dated memo the runbook names.
    def self.payout_memo(ref)
      return "printwright payout #{ref}" if ref
      "printwright designer payout #{Time.current.strftime('%Y-%m-%d')}"
    end

    # One notification per designer per state change, never per ledger row —
    # always called after its money transaction/attempt write already
    # committed, so a notification failure (swallowed by record_later) can
    # never touch the payout itself.
    def self.notify_payout_state(entries, kind:, asset:, tx_id: nil, error_code: nil, ref: nil)
      entries.group_by(&:designer).each do |designer, owed|
        Designers::Notifier.record_later(
          designer: designer, kind: kind,
          payload: {
            asset: asset, amount_base_units: owed.sum { |e| Integer(e.amount_base_units) }.to_s,
            tx_id: tx_id, ref: ref, error_code: error_code
          }.compact
        )
      end
    end
    private_class_method :with_advisory_lock, :notify_payout_state
  end
end
