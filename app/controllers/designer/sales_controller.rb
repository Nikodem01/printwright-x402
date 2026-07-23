require "csv"

# The designer statement: every sale as its ledger share row, with where the
# money is right now (paid direct / paid out / owed / refunded) and running
# owed balances. Rows come from the immutable ledger, not from purchases —
# what the designer sees is exactly what the books say.
class Designer::SalesController < Designer::BaseController
  class InvalidDateRange < StandardError; end

  PERIODS = { "30d" => 30.days, "90d" => 90.days, "all" => nil }.freeze
  MAX_CUSTOM_DAYS = 366

  def index
    load_statement(sales_filter)
  rescue InvalidDateRange => error
    load_statement(preset_filter("30d"))
    @start_date = params[:start_date].to_s
    @end_date = params[:end_date].to_s
    @filter_error = error.message
    render :index, status: :unprocessable_entity
  end

  def payouts
    @owed = LedgerEntry.owed.where(designer: current_designer).group(:asset).sum(:amount_base_units)
    @payout_rows = LedgerEntry.where(designer: current_designer, entry_kind: "designer_payout")
      .includes(purchase: { license_offer: :model3d }).order(created_at: :desc)
    @paid = @payout_rows.group_by(&:asset).transform_values { |rows| rows.sum(&:amount_base_units) }
    @payout_issue_groups = payout_issue_groups
    @payout_groups = @payout_rows.group_by { |row| [ row.tx_id.presence || "ledger-#{row.id}", row.asset ] }
      .map do |(tx_id, asset), rows|
        {
          tx_id: tx_id.start_with?("ledger-") ? nil : tx_id,
          asset: asset,
          paid_at: rows.map(&:created_at).max,
          amount: rows.sum(&:amount_base_units),
          sale_count: rows.size
        }
      end
      .sort_by { |group| group.fetch(:paid_at) }
      .reverse
  end

  def export
    filter = sales_filter
    rows = build_sale_rows(shares_for(filter))
    send_data sales_csv(rows), type: "text/csv; charset=utf-8",
      disposition: "attachment", filename: sales_filename(filter)
  rescue InvalidDateRange => error
    redirect_to designer_sales_path(start_date: params[:start_date].to_s,
      end_date: params[:end_date].to_s), alert: error.message
  end

  private

  def load_statement(filter)
    @period = filter.fetch(:key)
    @start_date = filter[:start_date]&.iso8601
    @end_date = filter[:end_date]&.iso8601
    @export_params = if @period == "custom"
      { start_date: @start_date, end_date: @end_date }
    else
      { period: @period }
    end
    @sale_rows = build_sale_rows(shares_for(filter))
    @totals = totals_for(@sale_rows)
    @owed = LedgerEntry.owed.where(designer: current_designer).group(:asset).sum(:amount_base_units)
  end

  def sales_filter
    return custom_filter if params[:start_date].present? || params[:end_date].present?

    key = PERIODS.key?(params[:period]) ? params[:period] : "30d"
    preset_filter(key)
  end

  def preset_filter(key)
    duration = PERIODS.fetch(key)
    { key: key, range: duration ? (duration.ago..) : nil }
  end

  def custom_filter
    start_text = params[:start_date].to_s
    end_text = params[:end_date].to_s
    if start_text.blank? || end_text.blank?
      raise InvalidDateRange, "Choose both a start date and an end date."
    end

    start_date = Date.iso8601(start_text)
    end_date = Date.iso8601(end_text)
    raise InvalidDateRange, "End date must be on or after the start date." if end_date < start_date
    if (end_date - start_date).to_i >= MAX_CUSTOM_DAYS
      raise InvalidDateRange, "Custom sales ranges can cover at most #{MAX_CUSTOM_DAYS} days."
    end
    if end_date > Time.current.utc.to_date
      raise InvalidDateRange, "End date cannot be in the future."
    end

    start_time = Time.utc(start_date.year, start_date.month, start_date.day)
    end_time = Time.utc(end_date.year, end_date.month, end_date.day) + 1.day
    { key: "custom", start_date: start_date, end_date: end_date,
      range: start_time...end_time }
  rescue Date::Error, TypeError
    raise InvalidDateRange, "Use valid dates in YYYY-MM-DD format."
  end

  def shares_for(filter)
    scope = LedgerEntry.where(designer: current_designer, entry_kind: "designer_share")
      .includes(purchase: [ :license, { license_offer: :model3d } ])
      .order(created_at: :desc)
    filter[:range] ? scope.where(created_at: filter.fetch(:range)) : scope
  end

  def sales_filename(filter)
    range = if filter.fetch(:key) == "custom"
      "#{filter.fetch(:start_date).iso8601}-to-#{filter.fetch(:end_date).iso8601}"
    else
      filter.fetch(:key)
    end
    "printwright-sales-#{range}-#{Date.current.iso8601}.csv"
  end

  def build_sale_rows(shares)
    purchase_ids = shares.map(&:purchase_id)
    related = LedgerEntry.where(purchase_id: purchase_ids)
    payouts = related.where(entry_kind: "designer_payout").index_by(&:purchase_id)
    refunds = related.where(entry_kind: "refund").index_by(&:purchase_id)
    shares.map do |share|
      purchase = share.purchase
      gross = purchase.amount_base_units.to_i
      payout = payouts[share.purchase_id]
      refund = refunds[share.purchase_id]
      {
        share: share, purchase: purchase, gross: gross,
        fee: gross - share.amount_base_units, payout: payout, refund: refund,
        status: sale_status(share, payout, refund)
      }
    end
  end

  def sale_status(share, payout, refund)
    return "Refunded to buyer" if refund
    return "Paid at settlement (legacy)" if share.held_by == "designer"
    return "Payout paid" if payout
    return "Payout pending" if current_designer.payout_account_verified?

    "Payout held"
  end

  def totals_for(rows)
    rows.group_by { |row| row.fetch(:share).asset }.transform_values do |asset_rows|
      {
        sales: asset_rows.size,
        gross: asset_rows.sum { |row| row.fetch(:gross) },
        fees: asset_rows.sum { |row| row.fetch(:fee) },
        net: asset_rows.sum { |row| row.fetch(:share).amount_base_units }
      }
    end
  end

  def sales_csv(rows)
    CSV.generate(headers: true) do |csv|
      csv << %w[sale_at_utc model license gross_base_units platform_fee_base_units designer_share_base_units
        asset payout_status payment_transaction payout_transaction refund_transaction certificate_id]
      rows.each do |row|
        purchase = row.fetch(:purchase)
        csv << [
          row.fetch(:share).created_at.utc.iso8601, csv_text(purchase.model3d.title),
          purchase.license_offer.kind, row.fetch(:gross), row.fetch(:fee),
          row.fetch(:share).amount_base_units, purchase.asset, row.fetch(:status),
          purchase.payment_tx_id, row[:payout]&.tx_id, row[:refund]&.tx_id,
          purchase.license&.cert_id
        ]
      end
    end
  end

  def csv_text(value)
    text = value.to_s
    text.match?(/\A[=+\-@\t\r\n]/) ? "'#{text}" : text
  end

  def payout_issue_groups
    issues = current_designer.payout_attempts.unresolved.order(last_attempted_at: :desc).to_a
    shares = LedgerEntry.where(designer: current_designer,
      purchase_id: issues.map(&:purchase_id), entry_kind: "designer_share")
      .index_by(&:purchase_id)
    issues.group_by { |attempt| [ attempt.ref, attempt.asset, attempt.status, attempt.last_error_code ] }
      .map do |(_ref, asset, status, error_code), attempts|
        {
          attempt: attempts.first, asset: asset, status: status, error_code: error_code,
          sale_count: attempts.size,
          amount: attempts.sum { |attempt| shares[attempt.purchase_id]&.amount_base_units.to_i },
          attempt_count: attempts.map(&:attempt_count).max,
          last_attempted_at: attempts.filter_map(&:last_attempted_at).max,
          retryable: attempts.all?(&:retryable?), tx_id: attempts.filter_map(&:tx_id).first
        }
      end
  end
end
