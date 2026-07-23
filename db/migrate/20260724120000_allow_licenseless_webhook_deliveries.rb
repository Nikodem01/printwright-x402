class AllowLicenselessWebhookDeliveries < ActiveRecord::Migration[8.1]
  # Test-ping deliveries have no underlying license. Real event deliveries
  # (sale.completed, certificate.anchored) still always set one.
  def change
    change_column_null :webhook_deliveries, :license_id, true
  end
end
