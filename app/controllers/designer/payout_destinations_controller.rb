class Designer::PayoutDestinationsController < Designer::BaseController
  rate_limit to: 10, within: 1.minute, name: "payout_destination_mutations",
    by: -> { "#{Current.designer&.id}:#{request.remote_ip}" }, store: RateLimitStore,
    with: :payout_rate_limited

  before_action -> { rodauth.require_two_factor_setup }
  before_action -> { rodauth.require_password_authentication }

  def create
    Designers::PayoutDestination.request!(
      designer: current_designer, account_id: params[:account_id]
    )
    redirect_to earnings_path, notice: "Destination staged. Connect that exact wallet and sign the challenge."
  rescue Designers::PayoutDestination::Error => error
    redirect_to earnings_path, alert: error_message(error)
  end

  def verify
    result = Designers::PayoutDestination.verify!(
      designer: current_designer,
      message: params[:message],
      signature_map: params[:signature_map]
    )
    notice = result == :activated ?
      "Payout destination proved and activated." :
      "Wallet control proved. The replacement is in a 24-hour safety hold; the current destination remains active."
    redirect_to earnings_path, notice: notice
  rescue Designers::PayoutDestination::Error => error
    redirect_to earnings_path, alert: error_message(error)
  end

  def activate
    account_id = Designers::PayoutDestination.activate!(designer: current_designer)
    redirect_to earnings_path, notice: "Payout destination changed to #{account_id}."
  rescue Designers::PayoutDestination::Error => error
    redirect_to earnings_path, alert: error_message(error)
  end

  def destroy
    Designers::PayoutDestination.cancel!(designer: current_designer)
    redirect_to earnings_path, notice: "Pending payout change cancelled. The active destination was not changed."
  rescue Designers::PayoutDestination::Error => error
    redirect_to earnings_path, alert: error_message(error)
  end

  private

  def earnings_path
    designer_payouts_path(anchor: "payout-destination")
  end

  def error_message(error)
    {
      invalid_account: "Enter a Hedera account id such as 0.0.12345.",
      already_active: "That wallet is already the proved active destination.",
      no_pending_change: "There is no pending payout change to act on.",
      challenge_expired: "That signing challenge expired. Start again to get a new one.",
      invalid_challenge: "The signing challenge changed. Start again before signing.",
      invalid_signature: "The wallet signature did not prove control of the staged account.",
      not_receivable: "That account cannot currently receive the configured USDC token.",
      verification_unavailable: "Wallet verification is temporarily unavailable. Your active destination was not changed.",
      hold_active: "The safety hold has not ended. You can cancel now or activate after the displayed time.",
      account_closed: "This account is closed and cannot change payout settings."
    }.fetch(error.code, error.message)
  end

  def payout_rate_limited
    redirect_to earnings_path, alert: "Too many payout-setting attempts. Wait a minute and try again."
  end
end
