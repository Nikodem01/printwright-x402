class Designer::AccountController < Designer::BaseController
  def show
    load_account
  end

  def update
    if current_designer.update(profile_params)
      redirect_to designer_account_path, notice: "Profile updated."
    else
      load_account
      render :show, status: :unprocessable_entity
    end
  end

  # Keep this session, sign out every other device (S5).
  def revoke_other_sessions
    rodauth.remove_all_active_sessions_except_current
    redirect_to designer_account_path, notice: "Signed out your other devices."
  end

  # GDPR data export (U2): everything we hold about this designer, as JSON.
  def export
    send_data Designers::AccountExport.new(current_designer).to_json,
      filename: "printwright-account-#{current_designer.id}.json",
      type: "application/json", disposition: "attachment"
  end

  private

  def load_account
    @designer = current_designer
    @sessions = current_designer.active_session_keys.order(last_use: :desc)
  end

  def profile_params
    params.require(:designer).permit(:display_name, :bio, :hedera_account_id)
  end
end
