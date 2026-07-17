class AddWarrantyAcceptedAtToModels3d < ActiveRecord::Migration[8.0]
  def change
    add_column :models3d, :warranty_accepted_at, :datetime
  end
end
