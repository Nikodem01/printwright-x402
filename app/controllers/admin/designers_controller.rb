class Admin::DesignersController < Admin::BaseController
  rate_limit to: 10, within: 1.minute, name: "mutations",
    by: -> { "#{Current.designer&.id}:#{request.remote_ip}" }, store: RateLimitStore,
    with: :admin_rate_limited

  before_action :set_designer

  def toggle_verification
    unless @designer.identity_verified?
      audit_failure!("designer_verification_revoke", @designer, StandardError.new("no verified proof"))
      return redirect_to admin_root_path, alert: "Identity badges can only be earned through public-profile proof."
    end

    @designer.transaction do
      @designer.update!(verified: false, identity_verified_at: nil, verified_profile_url: nil)
      @designer.profile_verifications.verified.update_all(status: "revoked", updated_at: Time.current)
      audit!("designer_verification_revoked", subject: @designer)
    end
    redirect_to admin_root_path, notice: "#{@designer.display_name}'s identity badge was revoked."
  rescue StandardError => error
    audit_failure!("designer_verification_revoke", @designer, error)
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
