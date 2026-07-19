class AnalyzeModelMeshJob < ApplicationJob
  queue_as :default

  def perform(model_id)
    model = Model3d.find(model_id)
    result = MeshAnalysis::Analyzer.call(model.printable_files)
    duplicate = duplicate_for(model, result)
    errors = result.errors.dup
    errors << duplicate_message(duplicate) if duplicate

    model.update_columns(
      mesh_analysis_status: errors.empty? ? "passed" : "failed",
      mesh_analysis_digest: result.digest,
      geometry_hash: result.geometry_hash,
      mesh_analysis: {
        "errors" => errors,
        "files" => result.files,
        "duplicate_model_id" => duplicate&.id
      },
      updated_at: Time.current
    )
  end

  private

  def duplicate_for(model, result)
    scope = Model3d.published.where.not(id: model.id)
    exact = scope.find_by(file_hash: result.digest)
    exact || (result.geometry_hash && scope.find_by(geometry_hash: result.geometry_hash))
  end

  def duplicate_message(model)
    "matches existing published model “#{model.title}”; contact support if you are authorized to republish it"
  end
end
