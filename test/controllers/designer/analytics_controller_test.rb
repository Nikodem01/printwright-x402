require "test_helper"

class Designer::AnalyticsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @designer = designers(:two)
    @model = @designer.models3d.create!(
      title: "Measured lamp", slug: "measured-lamp-#{SecureRandom.hex(4)}", status: "published"
    )
    @model.license_offers.create!(kind: "personal", price_cents: 100)
    sign_in_as @designer
  end

  test "shows aggregate discovery and canonical delivered sales per model" do
    ModelMetric.record!(model_ids: [ @model.id ], event: "impression",
      channel: "human", source: "search", occurred_on: Date.current.iso8601)
    ModelMetric.record!(model_ids: [ @model.id ], event: "view",
      channel: "human", source: "marketplace", occurred_on: Date.current.iso8601)
    ModelMetric.record!(model_ids: [ @model.id ], event: "payment_request",
      channel: "human", source: "checkout", occurred_on: Date.current.iso8601)
    delivered_purchase(@model)

    get designer_analytics_path

    assert_response :success
    assert_select "h1", text: "Analytics"
    assert_select ".analytics-summary", text: /Listing impressions.*1.*Detail views.*1.*x402 quote requests.*1.*Delivered sales.*1.*Gross revenue.*1\.00 USDC/m
    assert_select ".analytics-model-table tr", text: /Measured lamp.*Published.*1.*1.*100\.0%.*1.*100\.0%.*1/m
    assert_select ".analytics-breakdowns", text: /Human.*1.*1.*1/m
    assert_select ".analytics-privacy", text: /does not add a buyer id.*query text.*does not retain individual events/m
  end

  test "never exposes another designer's metrics, listings, sales, or payout state" do
    other = designers(:one)
    other_model = other.models3d.create!(
      title: "Private rival result", slug: "private-rival-#{SecureRandom.hex(4)}", status: "published"
    )
    other_model.license_offers.create!(kind: "personal", price_cents: 900)
    ModelMetric.record!(model_ids: [ other_model.id ], event: "impression",
      channel: "agent", source: "api_catalog", occurred_on: Date.current.iso8601)
    delivered_purchase(other_model, amount: "9000000")

    get designer_analytics_path(period: "all")

    assert_response :success
    assert_select ".analytics-summary", text: /Listing impressions.*0.*Delivered sales.*0/m
    refute_includes response.body, "Private rival result"
    refute_includes response.body, "9.00 USDC"
  end

  test "empty tracking state is honest and authentication is required" do
    get designer_analytics_path
    assert_response :success
    assert_select "p", text: /future public impressions and detail views.*not estimated or backfilled/m

    sign_out
    get designer_analytics_path
    assert_redirected_to "/login"
  end

  test "period presets filter aggregate traffic and canonical sales without changing history" do
    ModelMetric.record!(model_ids: [ @model.id ], event: "impression",
      channel: "human", source: "marketplace", occurred_on: 40.days.ago.to_date.iso8601)
    purchase = delivered_purchase(@model)
    LedgerEntry.where(purchase: purchase).update_all(created_at: 40.days.ago)

    get designer_analytics_path(period: "30d")
    assert_select ".analytics-summary", text: /Listing impressions.*0.*Delivered sales.*0/m

    get designer_analytics_path(period: "all")
    assert_select ".analytics-summary", text: /Listing impressions.*1.*Delivered sales.*1.*1\.00 USDC/m
    assert_equal 2, LedgerEntry.where(purchase: purchase).count
    assert_equal 1, @model.model_metrics.count
  end

  private

  def delivered_purchase(model, amount: "1000000")
    purchase = Purchase.create!(license_offer: model.license_offers.first, status: "verified",
      amount_base_units: amount, asset: X402::Requirements.usdc_asset,
      replay_key: SecureRandom.hex(32), requirements_json: { "payTo" => ENV.fetch("X402_PAY_TO") })
    purchase.transition_to!(:settled)
    purchase.transition_to!(:delivered)
    purchase
  end
end
