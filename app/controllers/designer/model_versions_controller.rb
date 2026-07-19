class Designer::ModelVersionsController < Designer::BaseController
  rate_limit to: 10, within: 1.minute, only: :create, store: RateLimitStore

  def create
    model = current_designer.models3d.find(params[:model_id])
    unless model.published?
      return redirect_to edit_designer_model_path(model), alert: "Publish the model before adding a version."
    end

    upload = params.dig(:model_version, :file)
    changelog = params.dig(:model_version, :changelog).to_s.strip
    return reject(model, "Choose one printable version file.") unless upload.respond_to?(:original_filename)
    return reject(model, "Describe what changed.") if changelog.blank?

    kind = File.extname(upload.original_filename).delete_prefix(".").downcase
    return reject(model, "Version files must be STL, 3MF, or STEP.") unless ModelVersion::FILE_KINDS.include?(kind)
    if (reason = Uploads::Validator.reason_to_reject(upload, kind: kind))
      return reject(model, "Rejected: #{reason}")
    end

    upload.rewind
    file_hash = "sha256:#{Digest::SHA256.hexdigest(upload.read)}"
    upload.rewind
    version = nil
    model.with_lock do
      version = model.model_versions.create!(
        number: model.model_versions.maximum(:number).to_i.clamp(1..) + 1,
        file_kind: kind,
        file_hash: file_hash,
        changelog: changelog,
        changelog_hash: "sha256:#{Digest::SHA256.hexdigest(changelog)}",
        published_at: Time.current
      )
      version.file.attach(upload)
    end
    ModelVersionAnchorJob.perform_later(version.id)
    redirect_to edit_designer_model_path(model), notice: "Version #{version.number} published; HCS anchoring queued."
  end

  private

  def reject(model, message)
    redirect_to edit_designer_model_path(model), alert: message
  end
end
