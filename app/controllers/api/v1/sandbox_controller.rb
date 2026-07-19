class Api::V1::SandboxController < Api::V1::BaseController
  rate_limit to: 120, within: 1.minute, store: RateLimitStore, with: :api_rate_limited

  def message
    license = sandbox_license_scope.find_by!(
      hcs_topic_id: params[:topic_id], hcs_sequence_number: params[:sequence_number]
    )
    render json: Sandbox::Topic.message(license)
  end

  def file
    license = sandbox_license_scope.find_by!(cert_id: params[:cert_id])
    receipt = <<~TEXT
      PRINTWRIGHT SANDBOX RECEIPT — NOT A PRINTABLE MODEL
      Certificate: #{license.cert_id}
      Model: #{license.purchase.model3d.title}
      #{Sandbox::Requirements::WARNING}
    TEXT
    send_data receipt, filename: "#{license.cert_id}-sandbox.txt",
      type: "text/plain", disposition: "attachment"
  end

  def transaction
    purchase = Purchase.where(sandbox: true).find_by!(payment_tx_id: params[:transaction_id])
    render json: {
      sandbox: true,
      warning: Sandbox::Requirements::WARNING,
      transaction_id: purchase.payment_tx_id,
      status: purchase.status,
      cert_id: purchase.license&.cert_id
    }
  end

  private

  def sandbox_license_scope
    License.joins(:purchase).where(purchases: { sandbox: true })
  end
end
