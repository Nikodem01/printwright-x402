class EarlyAccessSignupsController < ApplicationController
  allow_unauthenticated_access
  rate_limit to: 5, within: 1.minute, store: RateLimitStore

  def create
    email = EarlyAccessSignup.normalize_value_for(:email_address, params.require(:email_address))
    signup = EarlyAccessSignup.create_or_find_by!(email_address: email)
    EarlyAccessMailer.confirmation(signup).deliver_later if signup.previously_new_record?
    redirect_to root_path, notice: "You're on the designer early-access list."
  rescue ActiveRecord::RecordInvalid => error
    redirect_to root_path, alert: error.record.errors.full_messages.to_sentence
  end
end
