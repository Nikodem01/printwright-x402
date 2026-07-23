class AddMeshAnalysisToModelVersions < ActiveRecord::Migration[8.1]
  def up
    add_column :model_versions, :mesh_analysis_status, :string, null: false, default: "pending"
    add_column :model_versions, :mesh_analysis, :jsonb, null: false, default: {}
    add_column :model_versions, :geometry_hash, :string

    # Existing versions were delivered without mesh validation under the old
    # flow. Label them "skipped" (truthful, still deliverable) so buyers keep
    # receiving exactly what they receive today; only new uploads are gated.
    execute("UPDATE model_versions SET mesh_analysis_status = 'skipped'")
  end

  def down
    remove_column :model_versions, :mesh_analysis_status
    remove_column :model_versions, :mesh_analysis
    remove_column :model_versions, :geometry_hash
  end
end
