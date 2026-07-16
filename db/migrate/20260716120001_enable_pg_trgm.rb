class EnablePgTrgm < ActiveRecord::Migration[8.1]
  def change
    enable_extension "pg_trgm"
    # Speeds up similarity() lookups once the catalog grows.
    add_index :models3d, :title, using: :gin, opclass: :gin_trgm_ops, name: "index_models3d_on_title_trgm"
  end
end
