class CreateCatalogImports < ActiveRecord::Migration[8.0]
  def change
    create_table :catalog_imports do |t|
      t.references :designer, null: false, foreign_key: true
      t.string :status, null: false, default: "active"
      t.string :manifest_digest, null: false
      t.integer :model_count, null: false, default: 0
      t.jsonb :model_snapshots, null: false, default: {}
      t.datetime :completed_at
      t.datetime :rolled_back_at
      t.timestamps
    end
    add_index :catalog_imports, [ :designer_id, :created_at ]
    add_reference :models3d, :catalog_import, foreign_key: true
  end
end
