# Redeems a download grant token: counts the use, then redirects to the blob.
class Api::V1::FilesController < Api::V1::BaseController
  # A paid buyer re-fetching a multi-part bundle, or an agent working through a
  # batch, issues these back to back. Each request is one indexed lookup and a
  # redirect — the bytes come from the storage service, not from Rails — so the
  # limit is set well above any real order and exists only to stop a leaked
  # grant token from being used as a bandwidth pump.
  rate_limit to: 240, within: 1.minute, store: RateLimitStore, with: :api_rate_limited

  def show
    grant = DownloadGrant.find_by!(token: params[:token])
    return render json: { error: "grant_expired" }, status: :gone unless grant.usable?

    # Indexes address printable_files positionally and that order is stable, so
    # `f` keeps meaning the same part even if a sibling is later detached. No
    # `f` serves the first part exactly as before. Out of range, malformed, or
    # detached is a 404 — never a silent wrong file.
    files = grant.license.purchase.model3d.printable_files
    file = if params.key?(:f)
      index = Integer(params[:f], exception: false)
      index && index >= 0 ? files[index] : nil
    else
      files.first
    end
    return render json: { error: "file_not_found" }, status: :not_found if file.nil? || !file.file.attached?

    grant.consume!
    redirect_to rails_blob_path(file.file, disposition: "attachment"), allow_other_host: false
  end
end
