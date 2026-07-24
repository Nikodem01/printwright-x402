# Redeems a download grant token: counts the use, then redirects to the blob.
class Api::V1::FilesController < Api::V1::BaseController
  rate_limit to: 60, within: 1.minute, store: RateLimitStore, with: :api_rate_limited

  def show
    grant = DownloadGrant.find_by!(token: params[:token])
    return render json: { error: "grant_expired" }, status: :gone unless grant.usable?

    files = grant.license.purchase.model3d.printable_files
    # Backward compatible: no `f` param serves the first file exactly as before;
    # `f=N` serves the Nth file of a multi-part bundle. An out-of-range or
    # malformed index is a 404, never a silent wrong file.
    file = if params.key?(:f)
      index = Integer(params[:f], exception: false)
      index && index >= 0 ? files[index] : nil
    else
      files.first
    end
    return render json: { error: "file_not_found" }, status: :not_found if file.nil?

    grant.consume!
    redirect_to rails_blob_path(file.file, disposition: "attachment"), allow_other_host: false
  end
end
