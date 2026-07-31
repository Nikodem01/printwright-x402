class Api::V1::BaseController < ApplicationController
  skip_forgery_protection

  # Every API response carries the demo fact, not just the 402 — an agent that
  # lists the catalog or re-downloads a file never sees a payment challenge,
  # and must still be able to tell this is testnet. Set *before* the action,
  # not after: an action that raises into a `rescue_from` below never reaches
  # its after_action callbacks, and an agent hitting an error is exactly the
  # one that most needs to know which network it is talking to.
  before_action :mark_demo_environment

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

  def mark_demo_environment
    return unless X402::DemoNotice.active?
    response.set_header(X402::DemoNotice::HEADER, X402::DemoNotice.header_value)
  end

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
