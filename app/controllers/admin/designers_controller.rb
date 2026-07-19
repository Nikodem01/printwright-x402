class Admin::DesignersController < Admin::BaseController
  rate_limit to: 10, within: 1.minute, name: "mutations",
    by: -> { "#{Current.designer&.id}:#{request.remote_ip}" }, store: RateLimitStore,
    with: :admin_rate_limited

  before_action :set_designer

  def toggle_verification
    @designer.transaction do
      @designer.update!(verified: !@designer.verified?)
      audit!("designer_verification_toggled", subject: @designer,
        details: { verified: @designer.verified? })
    end
    redirect_to admin_root_path,
      notice: "#{@designer.display_name} is now #{@designer.verified? ? 'verified' : 'unverified'}."
  rescue StandardError => error
    audit_failure!("designer_verification_toggle", @designer, error)
    redirect_to admin_root_path, alert: "Designer update failed: #{error.message}"
  end

  def verify_payout
    audit!("designer_payout_check_requested", subject: @designer)
    verified = @designer.verify_payout_account!
    audit!("designer_payout_check_completed", subject: @designer, details: { verified: verified })
    redirect_to admin_root_path,
      notice: "#{@designer.display_name} payout account is #{verified ? 'ready' : 'not ready'}."
  rescue StandardError => error
    audit_failure!("designer_payout_check", @designer, error)
    redirect_to admin_root_path, alert: "Payout check failed: #{error.message}"
  end

  private

  def set_designer
    @designer = Designer.find(params[:id])
  end
end
