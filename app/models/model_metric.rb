# Daily aggregate only: no buyer/session/account id, IP, query text, referrer,
# user agent, or per-request event row is retained in the analytics table.
class ModelMetric < ApplicationRecord
  EVENTS = {
    "impression" => :impressions,
    "view" => :views,
    "payment_request" => :payment_requests
  }.freeze
  CHANNELS = %w[human agent].freeze
  SOURCES = %w[marketplace search category collection profile api_catalog api_search api
    checkout batch_checkout].freeze

  belongs_to :model3d

  validates :occurred_on, presence: true
  validates :channel, inclusion: { in: CHANNELS }
  validates :source, inclusion: { in: SOURCES }
  validates :impressions, :views, :payment_requests,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :model3d_id, uniqueness: { scope: %i[occurred_on channel source] }

  def self.record!(model_ids:, event:, channel:, source:, occurred_on:)
    column = EVENTS.fetch(event.to_s)
    raise ArgumentError, "unknown analytics channel" unless channel.to_s.in?(CHANNELS)
    raise ArgumentError, "unknown analytics source" unless source.to_s.in?(SOURCES)

    ids = Model3d.where(id: Array(model_ids).map(&:to_i).uniq).pluck(:id)
    return if ids.empty?

    now = Time.current
    rows = ids.map do |model_id|
      {
        model3d_id: model_id, occurred_on: Date.iso8601(occurred_on.to_s),
        channel: channel, source: source, impressions: column == :impressions ? 1 : 0,
        views: column == :views ? 1 : 0,
        payment_requests: column == :payment_requests ? 1 : 0,
        created_at: now, updated_at: now
      }
    end
    upsert_all(rows, unique_by: "index_model_metrics_on_daily_dimension",
      on_duplicate: Arel.sql(
        "#{column} = model_metrics.#{column} + EXCLUDED.#{column}, updated_at = EXCLUDED.updated_at"
      ))
  end
end
