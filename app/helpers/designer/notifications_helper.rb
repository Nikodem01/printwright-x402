module Designer::NotificationsHelper
  # Plain-language title per kind. A future kind without an entry here still
  # renders (humanized fallback) rather than raising.
  NOTIFICATION_TITLES = {
    "sale_delivered" => "Sale delivered",
    "certificate_anchored" => "Certificate anchored on Hedera",
    "payout_completed" => "Payout completed",
    "payout_failed" => "Payout failed",
    "payout_reconciliation_required" => "Payout needs reconciliation",
    "payout_destination_staged" => "Payout destination change requested",
    "payout_destination_hold" => "Payout destination replacement on hold",
    "payout_destination_activated" => "Payout destination activated",
    "payout_destination_cancelled" => "Payout destination change cancelled",
    "webhook_delivery_failed" => "Webhook delivery failed",
    "mesh_analysis_passed" => "Mesh analysis passed",
    "mesh_analysis_failed" => "Mesh analysis failed",
    "identity_verification_passed" => "Identity verified",
    "identity_verification_failed" => "Identity verification failed"
  }.freeze

  def notification_title(notification)
    NOTIFICATION_TITLES.fetch(notification.kind, notification.kind.humanize)
  end

  def notification_detail(notification)
    payload = notification.payload
    case notification.kind
    when "sale_delivered"
      unit = payload["serial"].present? ? ", unit #{payload['serial']}" : ""
      "#{payload['license_type'].to_s.humanize} license#{unit} — " \
        "#{format_base_units(payload['amount_base_units'].to_i, payload['asset'])}"
    when "certificate_anchored"
      "HCS sequence ##{payload['hcs_sequence_number']}"
    when "payout_completed"
      amount = format_base_units(payload["amount_base_units"].to_i, payload["asset"])
      payload["tx_id"] ? "#{amount} — #{payload['tx_id']}" : amount
    when "payout_failed"
      "#{format_base_units(payload['amount_base_units'].to_i, payload['asset'])} could not be sent " \
        "(#{payload['error_code']})"
    when "payout_reconciliation_required"
      "#{format_base_units(payload['amount_base_units'].to_i, payload['asset'])} needs manual reconciliation"
    when "payout_destination_staged"
      "New destination #{payload['hedera_account_id']} is awaiting wallet proof"
    when "payout_destination_hold"
      "Replacement #{payload['hedera_account_id']} is held until #{payload['hold_until']}"
    when "payout_destination_activated"
      "Payouts now go to #{payload['hedera_account_id']}"
    when "payout_destination_cancelled"
      "Change to #{payload['hedera_account_id']} was cancelled; your active destination is unchanged"
    when "webhook_delivery_failed"
      "#{payload['event_type']} to #{payload['url']}: #{payload['last_error']}"
    when "mesh_analysis_passed"
      "The printable file passed automated mesh analysis"
    when "mesh_analysis_failed"
      Array(payload["errors"]).join("; ")
    when "identity_verification_passed"
      "Verified from #{payload['host']}"
    when "identity_verification_failed"
      "#{payload['host']}: #{payload['reason']}"
    end
  end

  def notification_link(notification)
    case notification.kind
    when "sale_delivered", "certificate_anchored"
      [ "View statement", designer_sales_path ]
    when "payout_completed", "payout_failed", "payout_reconciliation_required"
      [ "Review payouts", designer_payouts_path(anchor: "payout-attention") ]
    when "payout_destination_staged", "payout_destination_hold",
         "payout_destination_activated", "payout_destination_cancelled"
      [ "Review payout destination", designer_payouts_path(anchor: "payout-destination") ]
    when "webhook_delivery_failed"
      [ "Review webhook deliveries", designer_webhook_endpoints_path(anchor: "delivery-health") ]
    when "mesh_analysis_passed", "mesh_analysis_failed"
      notification.model3d && [ "Open model", edit_designer_model_path(notification.model3d) ]
    when "identity_verification_passed", "identity_verification_failed"
      [ "Open identity", designer_identity_path ]
    end
  end
end
