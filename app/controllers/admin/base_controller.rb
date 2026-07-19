class Admin::BaseController < ApplicationController
  layout "admin"

  before_action :require_admin
  rate_limit to: 60, within: 1.minute, name: "all",
    by: -> { "#{Current.designer&.id}:#{request.remote_ip}" },
    store: RateLimitStore, with: :admin_rate_limited

  private

  def require_admin
    head :forbidden unless Current.designer&.admin?
  end

  def audit!(action, subject: nil, details: {})
    AdminAuditLog.create!(
      actor_designer: Current.designer,
      action: action,
      subject_type: subject&.class&.base_class&.name,
      subject_id: subject&.id,
      details: details.compact,
      request_id: request.request_id,
      ip_address: request.remote_ip
    )
  end

  def audit_failure!(action, subject, error)
    audit!("#{action}_failed", subject: subject,
      details: { error: error.class.name, message: error.message.to_s.first(240) })
  end

  def admin_rate_limited
    audit!("admin_rate_limit_blocked", details: { controller: controller_path, action: action_name }) if Current.designer&.admin?
    render plain: "Too many operator requests. Try again in one minute.", status: :too_many_requests
  end
end
