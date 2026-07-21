class LibraryMembershipsController < ApplicationController
  rate_limit to: 5, within: 1.minute, store: RateLimitStore

  def create
    license = License.includes(:library_membership, :purchase).find_by!(cert_id: params[:cert_id])
    authorized = License.find_signed(params[:token], purpose: "purchase-receipt")
    unless authorized == license && license.purchase.delivered? && !license.purchase.sandbox?
      raise ActiveRecord::RecordNotFound
    end

    membership = license.library_membership || license.build_library_membership
    membership.email_address = params.require(:email_address)
    membership.save!
    LibraryMailer.access(membership.email_address).deliver_later
    redirect_to purchase_receipt_path(license.cert_id, token: params[:token]),
      notice: "Check your email for a private library link."
  rescue ActiveRecord::RecordInvalid => error
    redirect_to purchase_receipt_path(params[:cert_id], token: params[:token]),
      alert: error.record.errors.full_messages.to_sentence
  end
end
