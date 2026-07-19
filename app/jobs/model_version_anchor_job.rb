# Anchors an additive model update on HCS. The PWC-1 license certificate and
# its original model hash are never rewritten.
class ModelVersionAnchorJob < ApplicationJob
  queue_as :default
  retry_on SidecarClient::Unavailable, wait: :polynomially_longer, attempts: 10

  def perform(model_version_id)
    version = ModelVersion.find(model_version_id)
    return if version.anchored?

    version.update!(event_json: version.anchor_payload) if version.event_json.blank?
    receipt = SidecarClient.new.submit_version(version.event_json)
    version.update!(
      hcs_topic_id: receipt["topicId"],
      hcs_sequence_number: receipt["sequenceNumber"],
      hcs_transaction_id: receipt["transactionId"]
    )
  end
end
