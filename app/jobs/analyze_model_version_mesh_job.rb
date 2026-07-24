# Validates a model-version file before buyers can receive it, then anchors it
# on HCS only once it is deliverable. The original certified bundle and every
# prior version are never touched.
class AnalyzeModelVersionMeshJob < ApplicationJob
  queue_as :default

  def perform(model_version_id)
    version = ModelVersion.find_by(id: model_version_id)
    return unless version&.file&.attached?

    # Analyze the whole bundle. A version predating multi-file bundles has no
    # version_files yet, so it falls back to its single `file` — the exact
    # behavior this job had before bundles existed.
    files = version.version_files.any? ? version.analyzer_inputs : [ version.analyzer_input ]

    if files.all? { |file| MeshAnalysis::Analyzer::SUPPORTED_KINDS.include?(file.kind) }
      result = MeshAnalysis::Analyzer.call(files)
      version.update!(
        mesh_analysis_status: result.errors.empty? ? "passed" : "failed",
        geometry_hash: result.geometry_hash,
        mesh_analysis: { "errors" => result.errors, "files" => result.files }
      )
    else
      # STEP and any other format the analyzer cannot inspect: a bundle
      # containing one cannot be validated as a whole, so it is accepted
      # without mesh validation, exactly as a lone STEP file was before, and
      # delivered to buyers.
      version.update!(mesh_analysis_status: "skipped")
    end

    ModelVersionAnchorJob.perform_later(version.id) if version.reload.deliverable?
  end
end
