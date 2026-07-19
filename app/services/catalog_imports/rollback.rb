module CatalogImports
  class Rollback
    def self.call(catalog_import)
      catalog_import.with_lock do
        raise Error, "batch is already rolled back" unless catalog_import.active?

        models = catalog_import.models3d.includes(:license_offers, model_files: { file_attachment: :blob }).to_a
        changed = models.reject do |model|
          expected = catalog_import.model_snapshots[model.id.to_s]
          model.draft? && expected.present? && Snapshot.digest(model) == expected
        end
        if changed.any?
          raise Error, "changed or published drafts: #{changed.map(&:slug).join(', ')}"
        end

        removed = models.length
        models.each(&:destroy!)
        catalog_import.update!(status: "rolled_back", rolled_back_at: Time.current)
        removed
      end
    end
  end
end
