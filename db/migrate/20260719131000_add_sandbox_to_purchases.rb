class AddSandboxToPurchases < ActiveRecord::Migration[8.1]
  def change
    add_column :purchases, :sandbox, :boolean, default: false, null: false
    add_index :purchases, :sandbox
  end
end
