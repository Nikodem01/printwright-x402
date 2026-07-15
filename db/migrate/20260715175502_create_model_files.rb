class CreateModelFiles < ActiveRecord::Migration[8.1]
  def change
    create_table :model_files do |t|
      t.references :model3d, null: false, foreign_key: { to_table: :models3d }
      t.string :kind, null: false
      t.integer :position, null: false, default: 0

      t.timestamps
    end
  end
end
