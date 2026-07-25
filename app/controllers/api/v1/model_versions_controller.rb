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
      download_url: api_v1_license_latest_version_file_url(@license.cert_id),
      files: bundle_files,
      # What the on-chain event commits to. Recompute it from `files` — SHA-256
      # over the RFC 8785 canonicalization of [{kind, hash}, ...] in order — and
      # compare with the anchored message to prove the bundle is the one that
      # was published, however many files it contains.
      files_hash: version&.files_hash
    }
  end

  def file
    if params.key?(:f)
      index = Integer(params[:f], exception: false)
      bundle = index && index >= 0 ? bundle_file(index) : nil
      raise ActiveRecord::RecordNotFound if bundle.nil? || !bundle.file.attached?

      return redirect_to rails_blob_path(bundle.file, disposition: "attachment"), allow_other_host: false
    end

    redirect_to rails_blob_path(latest_version&.file || original_file.file, disposition: "attachment"),
      allow_other_host: false
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

  # Newest deliverable version: gated on passed (or format-unvalidatable)
  # analysis, so a buyer never receives a pending or failed update and keeps
  # the previous deliverable bundle until the new one passes.
  def latest_version
    @latest_version ||= @license.purchase.model3d.model_versions
      .order(number: :desc).detect { |version| version.file.attached? && version.deliverable? }
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

  # The resolved version's ordered file bundle, or the original certified
  # bundle's printable files when no update has been published. `show` and
  # `file` index into this the same way, so a `files[i].download_url` from
  # `show` always resolves to the same file via `file?f=i`.
  def bundle_collection
    latest_version ? latest_version.version_files.ordered : @license.purchase.model3d.printable_files
  end

  def bundle_file(index)
    bundle_collection[index]
  end

  def bundle_files
    bundle_collection.each_with_index.map do |entry, index|
      {
        kind: entry.kind,
        file_hash: latest_version ? entry.file_hash : (index.zero? ? original_hash : nil),
        download_url: api_v1_license_latest_version_file_url(@license.cert_id, f: index)
      }.compact
    end
  end
end
