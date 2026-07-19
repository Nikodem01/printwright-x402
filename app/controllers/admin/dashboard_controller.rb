class Admin::DashboardController < Admin::BaseController
  def index
    @status = params[:status].presence_in(Purchase.statuses.keys)
    @purchases = Purchase.where(sandbox: false)
      .includes(:license, license_offer: :model3d).order(created_at: :desc)
    @purchases = @purchases.where(status: @status) if @status
    @purchases = @purchases.limit(100)
    @stuck_count = Purchase.where(sandbox: false, status: %w[pending verified])
      .where(created_at: ..30.minutes.ago).count
    @minting_licenses = License.joins(:purchase)
      .where(purchases: { sandbox: false, status: "delivered" }, hcs_sequence_number: nil)
      .includes(purchase: { license_offer: :model3d }).order(created_at: :asc).limit(100)
    @designers = Designer.order(:display_name)
    @ledger_totals = LedgerEntry.group(:entry_kind, :asset).sum(:amount_base_units)
    @owed_totals = LedgerEntry.owed.group(:asset).sum(:amount_base_units)
    @audit_logs = AdminAuditLog.includes(:actor_designer).order(created_at: :desc).limit(30)
    @sandbox_count = Purchase.where(sandbox: true).count
  end
end
