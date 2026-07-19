module Sandbox
  # Built-in mock of the facilitator's verify/settle contract. It never talks
  # to Hedera and accepts only the conspicuously fake sandbox transaction made
  # by @printwright/client.
  class Facilitator
    TRANSACTION_PATTERN = /\Asandbox:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

    def verify(payment_payload, payment_requirements)
      transaction = payment_payload.dig("payload", "transaction").to_s
      accepted = payment_payload["accepted"]
      valid = transaction.match?(TRANSACTION_PATTERN) && accepted == payment_requirements.deep_stringify_keys
      {
        "isValid" => valid,
        "payer" => valid ? "sandbox-buyer" : nil,
        "invalidReason" => valid ? nil : "invalid_sandbox_payment"
      }
    end

    def settle(payment_payload, payment_requirements)
      verification = verify(payment_payload, payment_requirements)
      return { "success" => false, "errorReason" => verification["invalidReason"] } unless verification["isValid"]

      transaction = payment_payload.dig("payload", "transaction")
      {
        "success" => true,
        "sandbox" => true,
        "network" => Requirements::NETWORK,
        "transaction" => "sandbox-tx-#{Digest::SHA256.hexdigest(transaction)[0, 20]}",
        "payer" => "sandbox-buyer",
        "warning" => Requirements::WARNING
      }
    end
  end
end
