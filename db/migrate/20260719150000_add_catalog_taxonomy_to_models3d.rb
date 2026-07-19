class AddCatalogTaxonomyToModels3d < ActiveRecord::Migration[8.1]
  def change
    add_column :models3d, :category, :string
    add_column :models3d, :collections, :string, array: true, null: false, default: []
    add_index :models3d, :category
    add_index :models3d, :collections, using: :gin
  end
end
