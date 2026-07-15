class Api::V1::BaseController < ApplicationController
  allow_unauthenticated_access

  rescue_from ActiveRecord::RecordNotFound do
    render json: { error: "not_found" }, status: :not_found
  end
end
