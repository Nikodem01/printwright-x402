class Api::V1::ModelVersionsController < Api::V1::BaseController
  rate_limit to: 60, within: 1.minute, store: RateLimitStore, with: :api_rate_limited
  before_action :authorize_paid_license

  def show
    version = latest_version
    render json: {
      cert_id: @license.cert_id,
      version: version&.number || 1,
      file_kind: version&.file_kind || original_file.kind,
      file_hash: version&.file_hash || original_hash,
      original_certificate_hash: original_hash,
      changelog: version&.changelog,
      changelog_hash: version&.changelog_hash,
      published_at: version&.published_at&.iso8601,
      hcs_topic_id: version&.hcs_topic_id,
      hcs_sequence_number: version&.hcs_sequence_number,
      hcs_transaction_id: version&.hcs_transaction_id,
      hcs_mirror_url: mirror_url(version),
      download_url: api_v1_license_latest_version_file_url(@license.cert_id)
    }
  end

  def file
    attachment = latest_version&.file || original_file.file
    redirect_to rails_blob_path(attachment, disposition: "attachment"), allow_other_host: false
  end

  private

  def authorize_paid_license
    token = request.authorization.to_s.match(/\ABearer (.+)\z/)&.captures&.first
    return render json: { error: "receipt_required" }, status: :unauthorized if token.blank?

    @license = License.find_signed(token, purpose: "model-updates")
    raise ActiveRecord::RecordNotFound unless @license&.cert_id == params[:cert_id]
    if @license.purchase.sandbox? || !@license.purchase.delivered?
      render json: { error: "paid_license_required" }, status: :forbidden
    end
  end

  def latest_version
    @latest_version ||= @license.purchase.model3d.model_versions.order(number: :desc).detect { |version| version.file.attached? }
  end

  def original_file
    @original_file ||= @license.purchase.model3d.printable_files.find { |file| file.file.attached? } ||
      raise(ActiveRecord::RecordNotFound)
  end

  def original_hash
    @original_hash ||= @license.cert_json["model_hash"].presence || @license.purchase.model3d.file_hash
  end

  def mirror_url(version)
    return unless version&.anchored?

    "#{Hedera::Network.mirror_base}/api/v1/topics/#{version.hcs_topic_id}/messages/#{version.hcs_sequence_number}"
  end
end
