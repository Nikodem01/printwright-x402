require "test_helper"

class ModelMetricTest < ActiveSupport::TestCase
  setup do
    @model = designers(:one).models3d.create!(
      title: "Aggregate metric", slug: "aggregate-metric-#{SecureRandom.hex(4)}"
    )
  end

  test "record aggregates the same daily dimension instead of retaining requests" do
    2.times do
      ModelMetric.record!(model_ids: [ @model.id ], event: "impression",
        channel: "human", source: "search", occurred_on: "2026-07-23")
    end
    ModelMetric.record!(model_ids: [ @model.id ], event: "view",
      channel: "human", source: "search", occurred_on: "2026-07-23")
    ModelMetric.record!(model_ids: [ @model.id ], event: "payment_request",
      channel: "human", source: "checkout", occurred_on: "2026-07-23")

    search_metric = @model.model_metrics.find_by!(source: "search")
    assert_equal 2, search_metric.impressions
    assert_equal 1, search_metric.views
    assert_equal 1, @model.model_metrics.find_by!(source: "checkout").payment_requests
  end

  test "record keeps source and channel dimensions separate" do
    ModelMetric.record!(model_ids: [ @model.id ], event: "impression",
      channel: "human", source: "marketplace", occurred_on: "2026-07-23")
    ModelMetric.record!(model_ids: [ @model.id ], event: "impression",
      channel: "agent", source: "api_catalog", occurred_on: "2026-07-23")

    assert_equal 2, @model.model_metrics.count
    assert_equal %w[agent human], @model.model_metrics.order(:channel).pluck(:channel)
  end

  test "schema has no buyer or request fingerprint fields" do
    forbidden = %w[buyer buyer_id account account_id session session_id ip ip_address
      query query_text referrer user_agent request_id]

    assert_empty ModelMetric.column_names & forbidden
  end

  test "unknown event and dimensions fail closed" do
    assert_raises(KeyError) do
      ModelMetric.record!(model_ids: [ @model.id ], event: "download",
        channel: "human", source: "marketplace", occurred_on: "2026-07-23")
    end
    assert_raises(ArgumentError) do
      ModelMetric.record!(model_ids: [ @model.id ], event: "view",
        channel: "crawler", source: "marketplace", occurred_on: "2026-07-23")
    end
  end
end
