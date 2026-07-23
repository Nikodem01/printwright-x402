class Designer::HomeController < Designer::BaseController
  def show
    models = current_designer.models3d
    @model_counts = models.group(:status).count

    shares = LedgerEntry.where(designer: current_designer, entry_kind: "designer_share")
    delivered_shares = shares.joins(:purchase).where(purchases: { status: "delivered" })
    delivered_purchase_ids = delivered_shares.select(:purchase_id)

    @completed_sale_count = delivered_shares.count
    @gross_by_asset = LedgerEntry.where(
      purchase_id: delivered_purchase_ids,
      entry_kind: %w[designer_share platform_fee]
    ).group(:asset).sum(:amount_base_units)
    @net_by_asset = delivered_shares.group(:asset).sum(:amount_base_units)
    @owed_by_asset = LedgerEntry.owed.where(designer: current_designer)
                                        .group(:asset).sum(:amount_base_units)
    @paid_by_asset = LedgerEntry.where(designer: current_designer, entry_kind: "designer_payout")
                                .group(:asset).sum(:amount_base_units)

    @recent_sales = delivered_shares
      .includes(purchase: { license_offer: :model3d })
      .order("purchases.updated_at DESC")
      .limit(5)
    @recent_models = models.order(updated_at: :desc).limit(5)
    @recent_imports = current_designer.catalog_imports.order(created_at: :desc).limit(3)
    @top_models = Purchase.joins(license_offer: :model3d)
      .where(models3d: { designer_id: current_designer.id }, status: "delivered", sandbox: false)
      .group("models3d.id", "models3d.title")
      .order(Arel.sql("COUNT(*) DESC"), "models3d.title")
      .limit(3)
      .count

    @failed_webhook_count = WebhookDelivery.where(
      webhook_endpoint_id: current_designer.webhook_endpoints.select(:id), status: "failed"
    ).count
    @unanchored_certificate_count = License.joins(purchase: { license_offer: :model3d })
      .where(models3d: { designer_id: current_designer.id }, purchases: { status: "delivered", sandbox: false })
      .where(hcs_sequence_number: nil)
      .count
    @payout_attention_count = current_designer.payout_attempts.unresolved.count

    @readiness = readiness_items
    @tasks = task_items
    @recent_activity = recent_activity
  end

  private

  def readiness_items
    [
      { label: "Email verified", complete: current_designer.email_verified?,
        detail: "Required before the first listing can be published." },
      { label: "Catalog started", complete: @model_counts.values.sum.positive?,
        detail: "Upload one model or bring in an existing catalog." },
      { label: "Listing live", complete: @model_counts.fetch("published", 0).positive?,
        detail: "A published listing is discoverable and available for checkout." },
      { label: "Payout destination ready", complete: current_designer.payout_account_verified?,
        detail: "Sales can happen before this; your share stays held until it is ready." }
    ]
  end

  def task_items
    tasks = []
    unless current_designer.email_verified?
      tasks << task("Verify your email", "Publishing stays locked until the account email is confirmed.",
        rodauth.verify_account_resend_path, "Send verification email",
        method: :post, params: { rodauth.login_param => current_designer.email_address })
    end

    model_count = @model_counts.values.sum
    draft_count = @model_counts.fetch("draft", 0)
    published_count = @model_counts.fetch("published", 0)
    if model_count.zero?
      tasks << task("Add your first model", "Start with one upload, or use Bulk import for an existing catalog.",
        new_designer_model_path, "Upload a model")
    elsif draft_count.positive?
      failed_drafts = current_designer.models3d.where(status: "draft", mesh_analysis_status: "failed")
      pending_drafts = current_designer.models3d.where(status: "draft", mesh_analysis_status: "pending")
      failed = failed_drafts.count
      pending = pending_drafts.count
      detail = if failed.positive?
        "#{failed} #{'draft has' if failed == 1}#{'drafts have' if failed != 1} a failed mesh check. Review the result before publishing."
      elsif pending.positive?
        "#{pending} #{'draft is' if pending == 1}#{'drafts are' if pending != 1} awaiting mesh analysis or a completed listing review."
      else
        "#{draft_count} #{'draft is' if draft_count == 1}#{'drafts are' if draft_count != 1} ready for your next review step."
      end
      recovery_model = failed_drafts.order(updated_at: :desc).first ||
        pending_drafts.order(updated_at: :desc).first ||
        current_designer.models3d.where(status: "draft").order(updated_at: :desc).first
      action = failed.positive? ? "Fix failed analysis" : (pending.positive? ? "Check analysis" : "Review draft")
      tasks << task("Finish #{helpers.pluralize(draft_count, 'draft listing')}", detail,
        edit_designer_model_path(recovery_model, anchor: "files"), action)
    elsif published_count.zero?
      tasks << task("Reopen sales", "Your catalog has no published listing. Review paused or retired models before resuming sales.",
        designer_models_path, "Review models")
    end

    if current_designer.payout_destination_change_pending?
      tasks << task("Finish the payout destination change", payout_change_detail,
        designer_payouts_path(anchor: "payout-destination"), payout_change_action)
    elsif !current_designer.payout_account_verified?
      title = @owed_by_asset.any? ? "Unlock earnings awaiting payout" : "Set up a payout destination"
      tasks << task(title,
        "Prove control of a Hedera account that can receive USDC. Buyer checkout and delivery do not wait for this step.",
        designer_payouts_path(anchor: "payout-destination"), "Set up payouts")
    end

    if @payout_attention_count.positive?
      tasks << task("Resolve a payout transfer",
        "#{helpers.pluralize(@payout_attention_count, 'sale')} has a payout retry or reconciliation state. Buyer delivery and rights remain complete.",
        designer_payouts_path(anchor: "payout-attention"), "Review payout state")
    end

    if @unanchored_certificate_count.positive?
      tasks << task("Certificate anchoring is delayed",
        "#{helpers.pluralize(@unanchored_certificate_count, 'delivered sale')} still awaits its public HCS anchor. Buyer delivery remains available while marketplace operations retry it.",
        designer_sales_path, "Review sales")
    end
    if @failed_webhook_count.positive?
      tasks << task("Webhook delivery needs attention",
        "#{helpers.pluralize(@failed_webhook_count, 'seller webhook delivery')} failed independently of buyer settlement and delivery.",
        designer_webhook_endpoints_path(anchor: "delivery-health"), "Retry failed delivery")
    end

    latest_verification = current_designer.profile_verifications.order(created_at: :desc).first
    if latest_verification&.failed? || latest_verification&.expired?
      tasks << task("Retry public identity verification",
        "The last profile proof did not complete. Replace or retry it when your public profile is ready.",
        designer_identity_path, "Retry proof")
    end
    tasks
  end

  def payout_change_detail
    case current_designer.payout_destination_state
    when :awaiting_proof
      "Connect the exact staged wallet and sign its single-use control challenge."
    when :safety_hold
      "The current destination remains active during the visible 24-hour replacement hold."
    when :ready_to_activate
      "The safety hold ended; activate the proved destination or cancel the change."
    else
      "Review the staged destination and complete its next security step."
    end
  end

  def payout_change_action
    case current_designer.payout_destination_state
    when :awaiting_proof then "Sign wallet proof"
    when :safety_hold then "Review safety hold"
    when :ready_to_activate then "Activate destination"
    else "Continue payout setup"
    end
  end

  def task(title, detail, path, action, method: nil, params: nil)
    { title: title, detail: detail, path: path, action: action, method: method, params: params }
  end

  def recent_activity
    sales = @recent_sales.map do |share|
      purchase = share.purchase
      {
        at: purchase.updated_at, kind: "Sale delivered",
        title: purchase.license_offer.model3d.title,
        detail: "#{purchase.license_offer.kind.humanize} · #{helpers.format_base_units(purchase.amount_base_units.to_i, purchase.asset)}",
        path: designer_sales_path
      }
    end
    listings = @recent_models.map do |model|
      {
        at: model.updated_at, kind: "Listing #{model.status}", title: model.title,
        detail: model.published? ? "Discoverable and open for checkout" : "No new checkout in this state",
        path: edit_designer_model_path(model)
      }
    end
    imports = @recent_imports.map do |catalog_import|
      {
        at: catalog_import.completed_at || catalog_import.created_at,
        kind: "Catalog import #{catalog_import.status}",
        title: helpers.pluralize(catalog_import.model_count, "model"),
        detail: catalog_import.source_kind.to_s.humanize,
        path: designer_imports_path
      }
    end
    (sales + listings + imports).sort_by { |item| item.fetch(:at) }.reverse.first(8)
  end
end
