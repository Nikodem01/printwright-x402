class AddExternalCatalogProvenance < ActiveRecord::Migration[8.1]
  def change
    add_column :catalog_imports, :source_kind, :string
    add_column :catalog_imports, :source_url, :string
    add_column :catalog_imports, :provenance, :jsonb, null: false, default: {}

    add_column :models3d, :source_url, :string
    add_column :models3d, :source_license, :string
    add_column :models3d, :ownership_warranted_at, :datetime
  end
end
