module LicenseOffers
  class Reviser
    def self.call(model:, attributes:)
      attributes = attributes.to_h.stringify_keys
      id = attributes.delete("id")
      destroy = ActiveModel::Type::Boolean.new.cast(attributes.delete("_destroy"))
      blank_new_offer = id.blank? && attributes["price_usdc"].blank? &&
        attributes["price_cents"].blank?

      return if id.blank? && (destroy || blank_new_offer)

      normalized_attributes = LicenseOffer.normalize_price_attributes(attributes)
      return create!(model, attributes) if id.blank?

      offer = model.all_license_offers.find(id)
      offer.with_lock do
        raise ActiveRecord::RecordNotFound unless offer.active?
        return destroy!(offer) if destroy

        changes = normalized_attributes.select do |field, value|
          LicenseOffer::COMMERCIAL_IDENTITY_FIELDS.include?(field) &&
            offer.public_send(field).to_s != value.to_s
        end
        return offer if changes.empty?
        unless offer.commercial_identity_locked?
          offer.update!(attributes)
          return offer
        end

        offer.update_column(:active, false)
        model.all_license_offers.create!(
          attributes.merge(
            "active" => true,
            "revision" => offer.revision + 1,
            "supersedes" => offer,
            "terms_version" => offer.terms_version,
            "terms_md" => offer.terms_md,
            "currency" => attributes.fetch("currency", offer.currency)
          )
        )
      end
    end

    def self.create!(model, attributes)
      model.all_license_offers.create!(attributes.merge("active" => true))
    end
    private_class_method :create!

    def self.destroy!(offer)
      if offer.commercial_identity_locked?
        offer.update_column(:active, false)
      else
        offer.destroy!
      end
      offer
    end
    private_class_method :destroy!
  end
end
