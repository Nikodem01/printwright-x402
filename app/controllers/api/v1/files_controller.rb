# Redeems a download grant token: counts the use, then redirects to the blob.
class Api::V1::FilesController < Api::V1::BaseController
  rate_limit to: 60, within: 1.minute, store: RateLimitStore, with: :api_rate_limited

  def show
    grant = DownloadGrant.find_by!(token: params[:token])
    return render json: { error: "grant_expired" }, status: :gone unless grant.usable?

    grant.consume!
    file = grant.license.purchase.model3d.printable_files.first
    redirect_to rails_blob_path(file.file, disposition: "attachment"), allow_other_host: false
  end
end
