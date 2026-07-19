class Admin::LicensesController < Admin::BaseController
  rate_limit to: 10, within: 1.minute, name: "mutations",
    by: -> { "#{Current.designer&.id}:#{request.remote_ip}" }, store: RateLimitStore,
    with: :admin_rate_limited

  def retry_certificate
    license = nil
    license = License.joins(:purchase).where(purchases: { sandbox: false }).find(params[:id])
    if license.anchored?
      audit!("certificate_retry_refused", subject: license, details: { reason: "already_anchored" })
      return redirect_to admin_root_path, alert: "Certificate #{license.cert_id} is already anchored."
    end

    audit!("certificate_retry_requested", subject: license)
    CertMintJob.perform_later(license.id)
    audit!("certificate_retry_enqueued", subject: license)
    redirect_to admin_root_path, notice: "Certificate #{license.cert_id} queued for retry."
  rescue StandardError => error
    audit_failure!("certificate_retry", license, error)
    redirect_to admin_root_path, alert: "Certificate retry failed: #{error.message}"
  end
end
