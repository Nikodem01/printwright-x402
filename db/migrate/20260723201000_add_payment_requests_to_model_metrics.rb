class AddPaymentRequestsToModelMetrics < ActiveRecord::Migration[8.1]
  def change
    add_column :model_metrics, :payment_requests, :integer, null: false, default: 0
  end
end
