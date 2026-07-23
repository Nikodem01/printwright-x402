class RemoveLegacyPurchaseColumns < ActiveRecord::Migration[8.1]
  def change
    remove_column :purchases, :refund_tx_id, :string
  end
end
