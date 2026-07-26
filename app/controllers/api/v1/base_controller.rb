class Api::V1::BaseController < ApplicationController
  skip_forgery_protection

  rescue_from ActiveRecord::RecordNotFound do
    render json: { error: "not_found" }, status: :not_found
  end

  # Issuing a 402 asks the facilitator for the fee payer, so an outage can fail
  # a quote before any money is at stake. The paid legs rescue this themselves
  # (they also have a purchase to keep alive); this is the backstop that keeps
  # every other path on the documented contract instead of a 500.
  rescue_from FacilitatorClient::Unavailable do
    response.set_header("Retry-After", "5")
    render json: { error: "facilitator_unavailable", retry_after: 5 }, status: :service_unavailable
  end

  private

  def render_listing_unavailable(model)
    if model.paused?
      render json: { error: "sales_paused", listing_status: model.status }, status: :conflict
    elsif model.retired?
      render json: { error: "listing_retired", listing_status: model.status }, status: :gone
    else
      render json: { error: "listing_availability_changed" }, status: :conflict
    end
  end

  # Machine clients get a machine-readable 429 with a concrete Retry-After —
  # the error contract agents can code against.
  def api_rate_limited
    response.set_header("Retry-After", "60")
    render json: { error: "rate_limited", retry_after: 60 }, status: :too_many_requests
  end
end
