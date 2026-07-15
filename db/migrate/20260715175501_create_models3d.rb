class CreateModels3d < ActiveRecord::Migration[8.1]
  def change
    create_table :models3d do |t|
      t.references :designer, null: false, foreign_key: true
      t.string :title, null: false
      t.string :slug, null: false
      t.text :description
      t.string :tags, array: true, null: false, default: []
      t.jsonb :printability, null: false, default: {}
      t.string :file_hash
      t.string :status, null: false, default: "draft"

      t.timestamps
    end
    add_index :models3d, :slug, unique: true
    add_index :models3d, :tags, using: :gin
    add_index :models3d, :status
  end
end
