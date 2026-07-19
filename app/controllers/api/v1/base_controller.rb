class Api::V1::BaseController < ApplicationController
  allow_unauthenticated_access
  skip_forgery_protection

  rescue_from ActiveRecord::RecordNotFound do
    render json: { error: "not_found" }, status: :not_found
  end

  private

  # Machine clients get a machine-readable 429 with a concrete Retry-After —
  # the error contract agents can code against.
  def api_rate_limited
    response.set_header("Retry-After", "60")
    render json: { error: "rate_limited", retry_after: 60 }, status: :too_many_requests
  end
end
