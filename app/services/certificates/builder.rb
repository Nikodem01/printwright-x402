module Certificates
  # Builds the v1 license-certificate JSON (schema frozen for the bounty).
  # Compact facts only — must stay under the 1024-byte HCS single-chunk limit.
  class Builder
    def self.call(license)
      purchase = license.purchase
      offer = purchase.license_offer
      model = offer.model3d
      {
        "v" => 1,
        "cert_id" => license.cert_id,
        "model_id" => model.id,
        "model_hash" => model.file_hash,
        "designer" => model.designer.hedera_account_id.to_s,
        "license_type" => offer.kind,
        "unit_serial" => license.serial,
        "buyer_hint" => purchase.buyer_hint.presence || "bearer",
        "payment_tx" => purchase.payment_tx_id,
        "issued_at" => Time.current.utc.iso8601,
        "terms_hash" => offer.terms_hash.to_s
      }
    end
  end
end
