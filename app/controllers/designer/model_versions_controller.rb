class Designer::ModelVersionsController < Designer::BaseController
  rate_limit to: 10, within: 1.minute, only: :create, store: RateLimitStore

  def create
    model = current_designer.models3d.find(params[:model_id])
    unless model.published? || model.paused?
      return redirect_to edit_designer_model_path(model), alert: "Publish the model before adding a version."
    end

    # `files[]` is the multi-file bundle field; a lone `file` is still
    # accepted for backward compatibility and treated as a one-element bundle.
    uploads = Array(params.dig(:model_version, :files)).reject(&:blank?)
    uploads = Array(params.dig(:model_version, :file)).reject(&:blank?) if uploads.empty?
    changelog = params.dig(:model_version, :changelog).to_s.strip
    return reject(model, "Choose at least one printable version file.") if uploads.empty?
    return reject(model, "Describe what changed.") if changelog.blank?

    # Every file is validated before anything is created: one bad file
    # rejects the whole bundle so a partial bundle is never persisted.
    prepared = []
    uploads.each do |upload|
      return reject(model, "Choose one printable version file.") unless upload.respond_to?(:original_filename)

      kind = File.extname(upload.original_filename).delete_prefix(".").downcase
      return reject(model, "Version files must be STL, 3MF, or STEP.") unless ModelVersion::FILE_KINDS.include?(kind)
      if (reason = Uploads::Validator.reason_to_reject(upload, kind: kind))
        return reject(model, "Rejected: #{reason}")
      end

      upload.rewind
      file_hash = "sha256:#{Digest::SHA256.hexdigest(upload.read)}"
      upload.rewind
      prepared << { upload: upload, kind: kind, file_hash: file_hash }
    end

    version = nil
    oversize = false
    model.with_lock do
      version = model.model_versions.create!(
        number: model.model_versions.maximum(:number).to_i.clamp(1..) + 1,
        file_kind: prepared.first[:kind],
        file_hash: prepared.first[:file_hash],
        changelog: changelog,
        changelog_hash: "sha256:#{Digest::SHA256.hexdigest(changelog)}",
        published_at: Time.current
      )
      version.file.attach(prepared.first[:upload])
      prepared.each_with_index do |part, index|
        version_file = version.version_files.create!(position: index, kind: part[:kind], file_hash: part[:file_hash])
        # The primary (index 0) reuses the blob just attached to version.file
        # instead of re-reading its upload a second time.
        version_file.file.attach(index.zero? ? version.file.blob : part[:upload])
      end

      # The provenance event must fit one HCS message, and only now is the file
      # list known. Rejecting here beats accepting a version that would upload
      # cleanly and then never anchor.
      if version.anchor_payload_too_large?
        oversize = true
        raise ActiveRecord::Rollback
      end
    end
    if oversize
      return reject(model, "That bundle has too many files to anchor as one provenance record. " \
        "Split it into fewer files (about eight is the limit) and upload again.")
    end

    AnalyzeModelVersionMeshJob.perform_later(version.id)
    redirect_to edit_designer_model_path(model),
      notice: "Version #{version.number} uploaded. It is validated before buyers receive it, then anchored on HCS."
  end

  private

  def reject(model, message)
    redirect_to edit_designer_model_path(model), alert: message
  end
end
