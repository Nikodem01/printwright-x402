class Api::V1::LicensesController < Api::V1::BaseController
  rate_limit to: 120, within: 1.minute, store: RateLimitStore, with: :api_rate_limited

  def can
    license = License.find_by!(cert_id: params[:id])
    use = params[:use].to_s
    quantity = parse_quantity
    return render_invalid_use(use) unless Licensing::Permissions::USES.include?(use)
    return render json: sandbox_decision(license, use, quantity) if license.purchase.sandbox?

    policy = Licensing::Permissions.for_license(license)
    unless policy
      return render json: { error: "permissions_unavailable",
                            message: "no structured policy matches this certificate's anchored terms hash" },
        status: :conflict
    end

    result = Licensing::Permissions.decide(policy[:document], use, quantity)
    render json: decision_response(license, policy, use, quantity, result)
  rescue ArgumentError => error
    render json: { error: "invalid_quantity", message: error.message }, status: :unprocessable_content
  end

  private

  def parse_quantity
    raw = params[:qty].presence || "1"
    raise ArgumentError, "qty must be a positive integer" unless raw.to_s.match?(/\A[1-9]\d*\z/)

    quantity = raw.to_i
    raise ArgumentError, "qty must be at most 1000000" if quantity > 1_000_000
    quantity
  end

  def render_invalid_use(use)
    render json: { error: "invalid_use", use: use, allowed_uses: Licensing::Permissions::USES },
      status: :unprocessable_content
  end

  def sandbox_decision(license, use, quantity)
    {
      cert_id: license.cert_id,
      use: use,
      qty: quantity,
      allowed: false,
      reason_code: "sandbox_not_a_license",
      reason: "sandbox receipts are simulations, not licenses",
      sandbox: true,
      permissions: nil
    }
  end

  def decision_response(license, policy, use, quantity, result)
    {
      cert_id: license.cert_id,
      use: use,
      qty: quantity,
      license_kind: policy[:kind],
      unit_serial: license.serial,
      **result,
      permissions: policy[:document],
      certificate_url: api_v1_certificate_url(license.cert_id),
      terms: {
        version: policy[:version],
        hash: policy[:terms_hash],
        url: license_document_url(version: policy[:version], kind: policy[:kind]),
        permissions_url: license_document_url(version: policy[:version], kind: policy[:kind], format: :json)
      }
    }
  end
end
