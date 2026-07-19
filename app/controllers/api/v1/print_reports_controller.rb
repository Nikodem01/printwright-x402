class Api::V1::PrintReportsController < Api::V1::BaseController
  rate_limit to: 20, within: 1.minute, store: RateLimitStore, with: :api_rate_limited

  def create
    license = License.find_by!(cert_id: params[:cert_id])
    receipt_license = License.find_signed(params.require(:receipt_token), purpose: "print-feedback")
    raise ActiveRecord::RecordNotFound unless receipt_license == license

    unless license.purchase.delivered? && !license.purchase.sandbox?
      return render json: { error: "paid_license_required" }, status: :forbidden
    end

    report = license.print_report
    created = report.nil?
    report ||= license.create_print_report!
    render json: {
      cert_id: license.cert_id,
      successful_prints: reports_for_model(license).count
    }, status: created ? :created : :ok
  rescue ActionController::ParameterMissing
    render json: { error: "not_found" }, status: :not_found
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  private

  def reports_for_model(license)
    PrintReport.joins(license: { purchase: :license_offer })
      .where(license_offers: { model3d_id: license.purchase.model3d.id })
  end
end
