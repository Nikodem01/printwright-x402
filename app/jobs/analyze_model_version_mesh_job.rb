# Validates a model-version file before buyers can receive it, then anchors it
# on HCS only once it is deliverable. The original certified bundle and every
# prior version are never touched.
class AnalyzeModelVersionMeshJob < ApplicationJob
  queue_as :default

  def perform(model_version_id)
    version = ModelVersion.find_by(id: model_version_id)
    return unless version&.file&.attached?

    if MeshAnalysis::Analyzer::SUPPORTED_KINDS.include?(version.file_kind)
      result = MeshAnalysis::Analyzer.call([ version.analyzer_input ])
      version.update!(
        mesh_analysis_status: result.errors.empty? ? "passed" : "failed",
        geometry_hash: result.geometry_hash,
        mesh_analysis: { "errors" => result.errors, "files" => result.files }
      )
    else
      # STEP and other formats the analyzer cannot inspect: accepted without
      # mesh validation, exactly as before, and delivered to buyers.
      version.update!(mesh_analysis_status: "skipped")
    end

    ModelVersionAnchorJob.perform_later(version.id) if version.reload.deliverable?
  end
end
