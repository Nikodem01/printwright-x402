class AddRefundTxIdToPurchases < ActiveRecord::Migration[8.0]
  def change
    add_column :purchases, :refund_tx_id, :string
  end
end
