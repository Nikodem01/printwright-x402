class Admin::PurchasesController < Admin::BaseController
  rate_limit to: 10, within: 1.minute, name: "mutations",
    by: -> { "#{Current.designer&.id}:#{request.remote_ip}" }, store: RateLimitStore,
    with: :admin_rate_limited

  before_action :set_purchase, except: :reap

  def reconcile
    unless @purchase.pending? || @purchase.verified?
      audit!("purchase_reconcile_refused", subject: @purchase, details: { status: @purchase.status })
      return redirect_to admin_root_path, alert: "Purchase #{@purchase.id} is not in flight."
    end

    audit!("purchase_reconcile_requested", subject: @purchase)
    result = Purchases::Reaper.reconcile(@purchase)
    audit!("purchase_reconcile_completed", subject: @purchase, details: { result: result.action })
    redirect_to admin_root_path, notice: "Purchase #{@purchase.id}: #{result.action.humanize.downcase}."
  rescue StandardError => error
    audit_failure!("purchase_reconcile", @purchase, error)
    redirect_to admin_root_path, alert: "Reconcile failed: #{error.message}"
  end

  def reap
    minutes = Integer(params.fetch(:minutes, 30), exception: false)&.clamp(0, 1_440) || 30
    audit!("purchase_reap_requested", details: { minutes: minutes })
    results = Purchases::Reaper.call(older_than: minutes.minutes)
    counts = results.map(&:action).tally
    audit!("purchase_reap_completed", details: { minutes: minutes, results: counts })
    redirect_to admin_root_path,
      notice: "Reaper checked #{results.length} purchase(s): #{counts.presence || 'nothing stale'}."
  rescue StandardError => error
    audit_failure!("purchase_reap", nil, error)
    redirect_to admin_root_path, alert: "Reaper failed: #{error.message}"
  end

  def refund
    audit!("purchase_refund_requested", subject: @purchase)
    tx_id = Ledger::Refunder.call(@purchase)
    audit!("purchase_refund_completed", subject: @purchase, details: { transaction_id: tx_id })
    redirect_to admin_root_path, notice: "Purchase #{@purchase.id} refunded: #{tx_id}."
  rescue StandardError => error
    audit_failure!("purchase_refund", @purchase, error)
    redirect_to admin_root_path, alert: "Refund failed: #{error.message}"
  end

  private

  def set_purchase
    @purchase = Purchase.where(sandbox: false).find(params[:id])
  end
end
