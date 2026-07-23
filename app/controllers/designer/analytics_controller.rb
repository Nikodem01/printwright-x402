class Designer::AnalyticsController < Designer::BaseController
  PERIODS = { "30d" => 30.days, "90d" => 90.days, "all" => nil }.freeze

  def show
    @period = PERIODS.key?(params[:period]) ? params[:period] : "30d"
    period_start = PERIODS.fetch(@period)&.ago

    all_metrics = ModelMetric.joins(:model3d)
      .where(models3d: { designer_id: current_designer.id })
    @tracking_started_on = all_metrics.minimum(:occurred_on)
    metrics = period_start ? all_metrics.where(occurred_on: period_start.utc.to_date..) : all_metrics

    @impressions = metrics.sum(:impressions)
    @views = metrics.sum(:views)
    @payment_requests = metrics.sum(:payment_requests)
    @channel_rows = grouped_metrics(metrics, :channel)
    @source_rows = grouped_metrics(metrics, :source)

    shares = LedgerEntry.where(designer: current_designer, entry_kind: "designer_share")
      .joins(:purchase).where(purchases: { status: "delivered" })
    shares = shares.where(created_at: period_start..) if period_start
    @delivered_sales = shares.count
    @gross_by_asset = LedgerEntry.where(
      purchase_id: shares.select(:purchase_id),
      entry_kind: %w[designer_share platform_fee]
    ).group(:asset).sum(:amount_base_units)
    @owed_by_asset = LedgerEntry.owed.where(designer: current_designer)
      .group(:asset).sum(:amount_base_units)
    @payout_attention_count = current_designer.payout_attempts.unresolved.count

    metric_totals = metrics.group(:model3d_id).pluck(
      :model3d_id, Arel.sql("SUM(impressions)"), Arel.sql("SUM(views)"),
      Arel.sql("SUM(payment_requests)")
    ).to_h do |model_id, impressions, views, payment_requests|
      [ model_id, [ impressions.to_i, views.to_i, payment_requests.to_i ] ]
    end
    sales_by_model = shares.joins(purchase: { license_offer: :model3d })
      .group("models3d.id").count
    @model_rows = current_designer.models3d.order(:title).map do |model|
      impressions, views, payment_requests = metric_totals.fetch(model.id, [ 0, 0, 0 ])
      {
        model: model, impressions: impressions, views: views,
        view_rate: impressions.positive? ? (views.fdiv(impressions) * 100) : nil,
        payment_requests: payment_requests,
        quote_rate: views.positive? ? (payment_requests.fdiv(views) * 100) : nil,
        delivered_sales: sales_by_model.fetch(model.id, 0)
      }
    end
  end

  private

  def grouped_metrics(scope, dimension)
    scope.group(dimension).pluck(
      dimension, Arel.sql("SUM(impressions)"), Arel.sql("SUM(views)"),
      Arel.sql("SUM(payment_requests)")
    ).map do |name, impressions, views, payment_requests|
      {
        name: name, impressions: impressions.to_i, views: views.to_i,
        payment_requests: payment_requests.to_i
      }
    end.sort_by { |row| [ -row.fetch(:impressions), row.fetch(:name) ] }
  end
end
