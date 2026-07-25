# The payout sub-flow, and only the payout sub-flow: sign-up stays a wallet-free
# form and onboarding stays the dashboard checklist. This is the one place a
# designer is walked step by step, because it is the one step that can fail
# silently — a wallet that cannot receive USDC passes every check the designer
# can see and then strands the payout.
#
# There is no wizard state to keep. Each step is derived from the designer's own
# payout_destination_state, and the account being asked about travels in the
# URL, so refreshing, coming back tomorrow, or finishing on another device all
# land on the right step. Turbo swaps the answer in place when it can; without
# it the same request just re-renders the page.
class Designer::PayoutSetupController < Designer::BaseController
  rate_limit to: 20, within: 1.minute, name: "payout_setup_checks",
    by: -> { "#{Current.designer&.id}:#{request.remote_ip}" }, store: RateLimitStore,
    only: :check, with: :check_rate_limited

  def show
    @state = current_designer.payout_destination_state
    @account_id = candidate_account_id
    @owed = LedgerEntry.owed.where(designer: current_designer).group(:asset).sum(:amount_base_units)
    @receivable = receivability_for(@account_id)
  end

  # "Check my wallet" — the whole point of the USDC step. Answered from the
  # public mirror, so the designer can fix their wallet and re-ask until it is
  # right, instead of discovering the problem by signing and failing.
  def check
    account_id = params[:account_id].to_s.strip
    receivable = valid_account?(account_id) && Designers::PayoutAccountCheck.call(account_id)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "payout-receivability",
          partial: "designer/payout_setup/receivability",
          locals: { receivable: receivable, account_id: account_id }
        )
      end
      format.html { redirect_to designer_payout_setup_path(account_id: account_id) }
    end
  end

  private

  # What this flow is currently about: the account just asked about, else the
  # staged wallet waiting for proof, else the active destination.
  def candidate_account_id
    params[:account_id].presence&.strip ||
      current_designer.payout_pending_account_id.presence ||
      current_designer.hedera_account_id.presence
  end

  # Worth a mirror round-trip only while the answer can still change something:
  # once a destination is active, the state machine already knows.
  def receivability_for(account_id)
    return nil unless valid_account?(account_id)
    return nil unless params[:account_id].present? ||
      %i[awaiting_proof needs_proof].include?(@state)

    Designers::PayoutAccountCheck.call(account_id)
  end

  def valid_account?(account_id) = account_id.to_s.match?(/\A0\.0\.\d+\z/)

  def check_rate_limited
    redirect_to designer_payout_setup_path,
      alert: "Too many wallet checks in a row. Wait a minute and try again."
  end
end
