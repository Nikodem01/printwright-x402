module Analytics
  class Recorder
    def self.record_later(model_ids:, event:, channel:, source:)
      ids = Array(model_ids).filter_map { |id| Integer(id, exception: false) }.uniq
      return if ids.empty?

      RecordModelMetricsJob.perform_later(model_ids: ids, event: event,
        channel: channel, source: source, occurred_on: Time.current.utc.to_date.iso8601)
    rescue StandardError => error
      Rails.error.report(error, handled: true, context: {
        component: "analytics_recorder", event: event.to_s, model_count: ids&.length.to_i
      })
      nil
    end
  end
end
