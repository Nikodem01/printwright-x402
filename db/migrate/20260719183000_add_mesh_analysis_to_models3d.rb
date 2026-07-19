class AddMeshAnalysisToModels3d < ActiveRecord::Migration[8.0]
  def change
    add_column :models3d, :mesh_analysis_status, :string, default: "pending", null: false
    add_column :models3d, :mesh_analysis_digest, :string
    add_column :models3d, :geometry_hash, :string
    add_column :models3d, :mesh_analysis, :jsonb, default: {}, null: false

    add_index :models3d, :geometry_hash
    add_index :models3d, :mesh_analysis_status
  end
end
