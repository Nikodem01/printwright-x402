# Validates a model-version file before buyers can receive it, then anchors it
# on HCS only once it is deliverable. The original certified bundle and every
# prior version are never touched.
class AnalyzeModelVersionMeshJob < ApplicationJob
  queue_as :default

  def perform(model_version_id)
    version = ModelVersion.find_by(id: model_version_id)
    return unless version&.file&.attached?

    # Analyze the whole bundle. Every version has one: the controller creates at
    # least one on upload, and a migration backfilled every version predating
    # multi-file bundles (those with no attached file returned above, and they
    # are exactly the ones the backfill skipped). If that ever stops being true,
    # stop rather than guess: leaving the status `pending` keeps the version out
    # of `deliverable`, so a bundle we could not inspect never reaches a buyer.
    files = version.analyzer_inputs
    return if files.empty?

    # A file the analyzer cannot read speaks only for itself. Every STL and 3MF
    # in the bundle is inspected regardless of what sits beside it, so a STEP
    # companion can no longer suppress the verdict on the files it ships with.
    analyzable = files.select { |file| MeshAnalysis::Analyzer::SUPPORTED_KINDS.include?(file.kind) }

    if analyzable.any?
      result = MeshAnalysis::Analyzer.call(analyzable)
      version.update!(
        mesh_analysis_status: result.errors.empty? ? "passed" : "failed",
        geometry_hash: result.geometry_hash,
        mesh_analysis: { "errors" => result.errors, "files" => result.files }
      )
    else
      # Nothing in the bundle can be inspected, so there is no geometry verdict
      # to give and it is accepted as a lone STEP file always was. New uploads
      # of this shape are refused at the door instead.
      version.update!(mesh_analysis_status: "skipped")
    end

    ModelVersionAnchorJob.perform_later(version.id) if version.reload.deliverable?
  end
end
