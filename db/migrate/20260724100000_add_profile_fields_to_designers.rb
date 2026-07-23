class AddProfileFieldsToDesigners < ActiveRecord::Migration[8.1]
  def change
    add_column :designers, :specialty, :string
    add_column :designers, :location, :string
    add_column :designers, :profile_links, :jsonb, null: false, default: []
    add_reference :designers, :featured_model,
      foreign_key: { to_table: :models3d, on_delete: :nullify }
  end
end
