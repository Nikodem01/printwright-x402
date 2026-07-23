module Models
  class AnalysisQueue
    def self.call(model)
      model.update_columns(
        mesh_analysis_status: "pending", mesh_analysis_digest: nil,
        geometry_hash: nil, mesh_analysis: {}, updated_at: Time.current
      )
      AnalyzeModelMeshJob.perform_later(model.id) if model.printable_files.any? { |file| file.file.attached? }
    end
  end
end
