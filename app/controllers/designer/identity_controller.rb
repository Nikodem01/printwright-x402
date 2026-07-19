class Designer::IdentityController < Designer::BaseController
  rate_limit to: 5, within: 1.minute, only: %i[create verify], store: RateLimitStore

  def show
    @verification = current_designer.profile_verifications.order(created_at: :desc).first
  end

  def create
    verification = ProfileVerifications::Challenge.call(current_designer, params[:profile_url])
    redirect_to designer_identity_path,
      notice: "Challenge created. Add the exact proof token to your public profile, then verify."
  rescue ProfileVerifications::Fetcher::Error => error
    redirect_to designer_identity_path, alert: error.message
  end

  def verify
    verification = current_designer.profile_verifications.find(params[:verification_id])
    ProfileVerifications::Fetcher.call(verification)
    redirect_to designer_identity_path, notice: "Identity verified from #{verification.host}."
  rescue ProfileVerifications::Fetcher::Error => error
    redirect_to designer_identity_path, alert: "Verification failed: #{error.message}"
  end
end
