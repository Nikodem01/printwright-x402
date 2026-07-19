require "digest"
require "json"

module CatalogImports
  class Snapshot
    MODEL_FIELDS = %w[
      title slug description tags category collections printability status
      source_url source_license ownership_warranted_at
    ].freeze
    OFFER_FIELDS = %w[kind price_cents currency max_units terms_md terms_version].freeze

    def self.digest(model)
      payload = {
        model: model.attributes.slice(*MODEL_FIELDS),
        files: model.model_files.map do |file|
          [ file.kind, file.position, file.file.filename.to_s, file.file.blob.checksum ]
        end.sort,
        offers: model.license_offers.map { |offer| offer.attributes.slice(*OFFER_FIELDS) }
          .sort_by { |offer| [ offer.fetch("kind"), offer.fetch("price_cents") ] }
      }
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end
  end
end
