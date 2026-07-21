class LicenseLibraryController < ApplicationController
  rate_limit to: 5, within: 1.minute, only: :create, store: RateLimitStore

  def new
  end

  def create
    email = LibraryMembership.normalize_value_for(:email_address, params.require(:email_address))
    LibraryMailer.access(email).deliver_later if LibraryMembership.exists?(email_address: email)
    redirect_to new_license_library_path,
      notice: "If that email has saved licenses, a private library link is on its way."
  end

  def access
    email = LibraryMembership.email_from_token(params[:token])
    return redirect_to new_license_library_path, alert: "That library link is invalid or expired." unless email

    write_library_cookie(email)
    redirect_to license_library_path
  end

  def show
    email = current_library_email
    return redirect_to new_license_library_path unless email

    response.set_header("Cache-Control", "no-store")
    @memberships = LibraryMembership.where(email_address: email)
      .includes(license: { purchase: { license_offer: :model3d } }).order(created_at: :desc)
  end

  # Close the library on this browser only.
  def destroy
    cookies.delete(:license_library_email)
    redirect_to root_path, notice: "License library closed on this browser."
  end

  # Revoke every outstanding library cookie for this email (S7) — the leaked-cookie kill switch.
  def revoke_everywhere
    email = current_library_email
    LibraryAccess.revoke!(email) if email
    cookies.delete(:license_library_email)
    redirect_to new_license_library_path, notice: "Signed out of your library on all devices."
  end

  private

  def write_library_cookie(email)
    cookies.encrypted[:license_library_email] = {
      value: { email: email, v: LibraryAccess.current_version(email) }.to_json,
      expires: 30.days.from_now, httponly: true, same_site: :lax,
      secure: Rails.env.production?
    }
  end

  # Returns the cookie's email only if its embedded nonce still matches the
  # server's current version for that email; otherwise the cookie is stale/revoked.
  def current_library_email
    raw = cookies.encrypted[:license_library_email]
    return unless raw

    data = JSON.parse(raw) rescue nil
    return unless data.is_a?(Hash) && data["email"].present?
    return unless data["v"] == LibraryAccess.current_version(data["email"])

    data["email"]
  end
end
