module Certificates
  # Builds the v2 license-certificate JSON. Personal grants intentionally carry
  # no sequential sale number; commercial per-unit grants retain unit_serial.
  # Compact facts only — must stay under the 1024-byte HCS single-chunk limit.
  class Builder
    def self.call(license)
      purchase = license.purchase
      offer = purchase.license_offer
      model = offer.model3d
      certificate = {
        "v" => 2,
        "cert_id" => license.cert_id,
        "model_id" => model.id,
        "model_hash" => model.file_hash,
        "designer" => model.designer_id,
        "license_type" => offer.kind,
        "buyer_hint" => purchase.buyer_hint.presence || "bearer",
        "payment_tx" => purchase.payment_tx_id,
        "issued_at" => Time.current.utc.iso8601,
        "terms_hash" => offer.terms_hash.to_s
      }
      certificate["unit_serial"] = license.serial if offer.kind == "commercial_unit"
      certificate
    end
  end
end
