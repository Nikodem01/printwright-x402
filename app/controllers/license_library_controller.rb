class LicenseLibraryController < ApplicationController
  allow_unauthenticated_access
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

    cookies.encrypted[:license_library_email] = {
      value: email, expires: 30.days.from_now, httponly: true, same_site: :lax,
      secure: Rails.env.production?
    }
    redirect_to license_library_path
  end

  def show
    email = cookies.encrypted[:license_library_email]
    return redirect_to new_license_library_path unless email

    response.set_header("Cache-Control", "no-store")
    @memberships = LibraryMembership.where(email_address: email)
      .includes(license: { purchase: { license_offer: :model3d } }).order(created_at: :desc)
  end

  def destroy
    cookies.delete(:license_library_email)
    redirect_to root_path, notice: "License library closed on this browser."
  end
end
