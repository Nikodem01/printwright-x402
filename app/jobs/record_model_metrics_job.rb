class RecordModelMetricsJob < ApplicationJob
  queue_as :default

  def perform(model_ids:, event:, channel:, source:, occurred_on:)
    ModelMetric.record!(model_ids: model_ids, event: event, channel: channel,
      source: source, occurred_on: occurred_on)
  end
end
