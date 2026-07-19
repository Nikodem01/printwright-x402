namespace :mesh_analysis do
  desc "Analyze every model with attached printable files"
  task reindex: :environment do
    scope = Model3d.joins(model_files: { file_attachment: :blob })
                   .where(model_files: { kind: %w[stl 3mf step] }).distinct
    scope.find_each do |model|
      AnalyzeModelMeshJob.perform_now(model.id)
      puts "#{model.slug}: #{model.reload.mesh_analysis_status}"
    end
  end
end
