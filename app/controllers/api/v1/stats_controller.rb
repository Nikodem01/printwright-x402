class Api::V1::StatsController < Api::V1::BaseController
  rate_limit to: 120, within: 1.minute, store: RateLimitStore, with: :api_rate_limited

  def show
    render json: OpenBooks::Snapshot.call
  end
end
