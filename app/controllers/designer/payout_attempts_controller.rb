class Designer::PayoutAttemptsController < Designer::BaseController
  class NotRetryable < StandardError; end

  rate_limit to: 5, within: 1.minute, name: "payout_attempt_retries",
    by: -> { "#{Current.designer&.id}:#{request.remote_ip}" }, store: RateLimitStore,
    with: :payout_rate_limited

  before_action -> { rodauth.require_password_authentication }

  def retry
    attempt = current_designer.payout_attempts.find(params[:id])
    purchase_ids = nil
    already_resolved = false

    PayoutAttempt.transaction do
      PayoutAttempt.connection.execute(
        "SELECT pg_advisory_xact_lock(#{Ledger::PayoutRunner::ADVISORY_LOCK_KEY})"
      )
      attempt.lock!
      raise NotRetryable unless attempt.retryable?

      group = current_designer.payout_attempts.where(
        ref: attempt.ref, asset: attempt.asset, status: "failed",
        last_error_code: attempt.last_error_code
      ).lock
      purchase_ids = LedgerEntry.owed.where(
        designer: current_designer, asset: attempt.asset,
        purchase_id: group.select(:purchase_id)
      ).pluck(:purchase_id)
      if purchase_ids.empty?
        PayoutAttempt.reconcile_ref!(ref: attempt.ref, designer: current_designer)
        already_resolved = true
      else
        group.update_all(status: "retrying", updated_at: Time.current)
        DesignerPayoutJob.perform_later(purchase_ids: purchase_ids, ref: attempt.ref)
      end
    end

    if already_resolved
      return redirect_to designer_payouts_path(anchor: "payout-attention"),
        notice: "That payout was already resolved; no second transfer was queued."
    end

    redirect_to designer_payouts_path(anchor: "payout-attention"),
      notice: "Payout retry queued for the existing verified destination. No buyer action is repeated."
  rescue NotRetryable
    redirect_to designer_payouts_path(anchor: "payout-attention"),
      alert: "That payout can no longer be retried here. Refresh its state or follow the displayed recovery step."
  end

  private

  def payout_rate_limited
    redirect_to designer_payouts_path(anchor: "payout-attention"),
      alert: "Too many payout retries. Wait a minute and try again."
  end
end
