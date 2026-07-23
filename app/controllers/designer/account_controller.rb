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

  # Sign out one specific device. Scoped to this designer's own sessions; the
  # current session is refused so a designer cannot lock themselves out here.
  def revoke_session
    target = params[:session_id].to_s
    if current_session_ids.include?(target)
      return redirect_to designer_account_path, alert: "That is your current session; use sign out to end it."
    end

    current_designer.active_session_keys.where(session_id: target).delete_all
    redirect_to designer_account_path, notice: "Signed out that device."
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
    @current_session_ids = current_session_ids
  end

  # The stored session_id column holds compute_hmac(raw); compute_hmacs(raw)
  # returns that value (and any prior-secret variants), so membership marks the
  # current row exactly.
  def current_session_ids
    raw = rodauth.session[rodauth.session_id_session_key]
    raw ? Array(rodauth.compute_hmacs(raw)) : []
  end

  def profile_params
    params.require(:designer).permit(:display_name, :bio, :specialty, :location,
      :profile_links_text, :featured_model_id)
  end
end
