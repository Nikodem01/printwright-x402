class Admin::PayoutsController < Admin::BaseController
  rate_limit to: 5, within: 1.minute, name: "mutations",
    by: -> { "#{Current.designer&.id}:#{request.remote_ip}" }, store: RateLimitStore,
    with: :admin_rate_limited

  # Moving money requires a recent password entry (S3), not just a live session.
  before_action -> { rodauth.require_password_authentication }, only: :run

  def preview
    payouts = Ledger::PayoutRunner.call(dry_run: true)
    audit!("payout_previewed", details: payout_summary(payouts))
    redirect_to admin_root_path, notice: payout_notice(payouts, dry_run: true)
  rescue StandardError => error
    audit_failure!("payout_preview", nil, error)
    redirect_to admin_root_path, alert: "Payout preview failed: #{error.message}"
  end

  def run
    unless params[:confirm] == "1"
      audit!("payout_refused", details: { reason: "confirmation_missing" })
      return redirect_to admin_root_path, alert: "Payout run requires explicit confirmation."
    end

    audit!("payout_requested")
    payouts = Ledger::PayoutRunner.call
    audit!("payout_completed", details: payout_summary(payouts))
    redirect_to admin_root_path, notice: payout_notice(payouts, dry_run: false)
  rescue StandardError => error
    audit_failure!("payout", nil, error)
    redirect_to admin_root_path, alert: "Payout failed: #{error.message}"
  end

  private

  def payout_summary(payouts)
    { assets: payouts.map { |payout| {
      asset: payout.asset, transaction_id: payout.tx_id, recipients: payout.transfers.length
    } } }
  end

  def payout_notice(payouts, dry_run:)
    return "No payable designer balances." if payouts.empty?

    prefix = dry_run ? "Preview" : "Paid"
    "#{prefix}: #{payouts.sum { |payout| payout.transfers.length }} recipient(s) across #{payouts.length} asset(s)."
  end
end
