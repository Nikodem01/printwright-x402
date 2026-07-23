module Models
  class PublishReview
    PURPOSE = "model-publish-review"
    EXPIRY = 30.minutes

    def self.snapshot(model)
      files = model.model_files.includes(file_attachment: :blob).order(:position, :id).filter_map do |file|
        next unless file.file.attached?

        blob = file.file.blob
        {
          id: file.id, kind: file.kind, filename: blob.filename.to_s,
          checksum: blob.checksum, byte_size: blob.byte_size
        }
      end
      offers = model.license_offers.reload.map do |offer|
        {
          id: offer.id, revision: offer.revision, kind: offer.kind,
          price_cents: offer.price_cents, currency: offer.currency,
          max_units: offer.max_units, terms_version: offer.terms_version,
          terms_hash: offer.terms_hash, terms_text: offer.terms_text
        }
      end
      designer = model.designer.reload
      {
        model: {
          id: model.id, title: model.title, slug: model.slug, description: model.description,
          status: model.status, category: model.category, collections: model.collections,
          tags: model.tags, printability: model.printability, files: files,
          mesh_analysis_status: model.mesh_analysis_status,
          mesh_analysis_digest: model.mesh_analysis_digest,
          geometry_hash: model.geometry_hash,
          offers: offers
        },
        payout: {
          account_id: designer.hedera_account_id,
          verified_at: designer.payout_account_verified_at&.iso8601(6)
        },
        platform_fee_bps: LedgerEntry::PLATFORM_FEE_BPS
      }
    end

    def self.digest(model)
      digest_snapshot(snapshot(model))
    end

    def self.token(model, snapshot: snapshot(model))
      verifier.generate(
        { model_id: model.id, digest: digest_snapshot(snapshot) },
        expires_in: EXPIRY
      )
    end

    def self.valid?(model, token)
      return false if token.blank?

      payload = verifier.verify(token).with_indifferent_access
      expected = digest(model)
      payload[:model_id].to_i == model.id &&
        ActiveSupport::SecurityUtils.secure_compare(payload[:digest].to_s, expected)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ArgumentError
      false
    end

    def self.canonical(value)
      case value
      when Hash
        value.to_h.transform_keys(&:to_s).sort.to_h.transform_values { |item| canonical(item) }
      when Array
        value.map { |item| canonical(item) }
      else
        value
      end
    end
    private_class_method :canonical

    def self.digest_snapshot(snapshot)
      "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(snapshot)))}"
    end
    private_class_method :digest_snapshot

    def self.verifier
      Rails.application.message_verifier(PURPOSE)
    end
    private_class_method :verifier
  end
end
