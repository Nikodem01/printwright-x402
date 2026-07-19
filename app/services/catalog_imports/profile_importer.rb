require "digest"
require "json"
require "zip"

module CatalogImports
  class ProfileImporter
    PROFILE_BYTES = 1.megabyte
    MAX_TOTAL_FILE_BYTES = Importer::MAX_ARCHIVE_BYTES
    ALLOWED_LICENSES = %w[all-rights-reserved proprietary].freeze
    FILE_KINDS = %w[stl 3mf step render].freeze

    ModelPreview = Data.define(
      :external_id, :title, :slug, :source_url, :source_license, :compatible, :reason, :spec
    )
    Preview = Data.define(:feed_url, :digest, :profile_name, :profile_url, :models)
    ProfileUpload = Struct.new(:original_filename, :bytes) do
      def size = bytes.bytesize
      def read(length = nil) = length ? io.read(length) : io.read
      def rewind = io.rewind

      private

      def io
        @io ||= StringIO.new(bytes)
      end
    end

    class << self
      def preview(feed_url)
        bytes = RemoteFetcher.call(feed_url, max_bytes: PROFILE_BYTES, accept: "application/json")
        document = JSON.parse(bytes)
        validate_document(document, feed_url, bytes)
      rescue JSON::ParserError
        raise Error, "profile manifest is not valid JSON"
      end

      def call(designer, feed_url:, expected_digest:, external_ids:)
        profile = preview(feed_url)
        raise Error, "profile changed after review; review it again" unless profile.digest == expected_digest

        ids = Array(external_ids).map(&:to_s).uniq
        raise Error, "select and warrant at least one compatible model" if ids.empty?
        indexed = profile.models.index_by(&:external_id)
        unknown = ids - indexed.keys
        raise Error, "profile selection is no longer valid" if unknown.any?
        selected = ids.map { |id| indexed.fetch(id) }
        if (blocked = selected.find { |model| !model.compatible })
          raise Error, "#{blocked.title}: #{blocked.reason}"
        end

        archive = build_archive(selected)
        provenance = {
          catalog: {
            source_kind: "external_profile",
            source_url: profile.profile_url,
            provenance: {
              "feed_url" => profile.feed_url,
              "profile_digest" => profile.digest,
              "profile_name" => profile.profile_name,
              "external_model_ids" => selected.map(&:external_id),
              "ownership_warranty_version" => "v1"
            }
          },
          models: selected.to_h do |model|
            [ model.slug, {
              source_url: model.source_url,
              source_license: model.source_license,
              ownership_warranted_at: Time.current
            } ]
          end
        }
        Importer.call(designer, archive, provenance: provenance)
      end

      private

      def validate_document(document, feed_url, bytes)
        unless document.is_a?(Hash) && document["schema_version"] == 1
          raise Error, "profile schema_version must be 1"
        end
        profile = document["profile"]
        raise Error, "profile metadata must be an object" unless profile.is_a?(Hash)
        profile_name = profile["name"].to_s.strip
        profile_url = validated_https(profile["url"], "profile URL")
        raise Error, "profile name is missing" if profile_name.blank?

        models = document["models"]
        unless models.is_a?(Array) && models.length.between?(1, Importer::MAX_MODELS)
          raise Error, "profile models must contain 1 to #{Importer::MAX_MODELS} items"
        end
        previews = models.map.with_index { |model, index| validate_model(model, index + 1) }
        file_count = previews.sum { |model| model.spec.fetch("files").length }
        if file_count > Importer::MAX_ENTRIES - 1
          raise Error, "profile has more than #{Importer::MAX_ENTRIES - 1} files"
        end
        ids = previews.map(&:external_id)
        slugs = previews.map(&:slug)
        raise Error, "profile model ids must be unique" unless ids.uniq.length == ids.length
        raise Error, "profile model slugs must be unique" unless slugs.uniq.length == slugs.length

        Preview.new(
          feed_url: feed_url.to_s,
          digest: "sha256:#{Digest::SHA256.hexdigest(bytes)}",
          profile_name: profile_name,
          profile_url: profile_url,
          models: previews.freeze
        )
      end

      def validate_model(model, number)
        raise Error, "profile model #{number} must be an object" unless model.is_a?(Hash)
        external_id = model["id"].to_s.strip
        title = model["title"].to_s.strip
        slug = model["slug"].to_s.strip
        unless external_id.match?(/\A[a-zA-Z0-9._:-]{1,100}\z/)
          raise Error, "profile model #{number} has an invalid id"
        end
        raise Error, "profile model #{number} needs a title" if title.blank?
        unless slug.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
          raise Error, "#{external_id}: invalid slug"
        end

        source_url = validated_https(model["source_url"], "#{external_id} source URL")
        source_license = model["source_license"].to_s.strip.downcase
        files = validate_files(external_id, model["files"])
        offers = validate_offers(external_id, model["offers"])
        compatible, reason = compatibility(source_license)
        tags = model.fetch("tags", [])
        collections = model.fetch("collections", [])
        printability = model["printability"]
        raise Error, "#{external_id}: tags must be an array" unless tags.is_a?(Array)
        raise Error, "#{external_id}: collections must be an array" unless collections.is_a?(Array)
        if model["category"].present? && !Model3d::CATEGORIES.key?(model["category"])
          raise Error, "#{external_id}: unknown category #{model['category']}"
        end
        unknown_collections = collections - Model3d::COLLECTIONS.keys
        if unknown_collections.any?
          raise Error, "#{external_id}: unknown collections #{unknown_collections.join(', ')}"
        end
        unless printability.nil? || printability.is_a?(Hash)
          raise Error, "#{external_id}: printability must be an object"
        end
        spec = {
          "title" => title,
          "slug" => slug,
          "description" => model["description"].to_s,
          "tags" => tags.map(&:to_s),
          "category" => model["category"],
          "collections" => collections,
          "printability" => printability,
          "files" => files,
          "offers" => offers
        }
        ModelPreview.new(
          external_id: external_id, title: title, slug: slug, source_url: source_url,
          source_license: source_license, compatible: compatible, reason: reason, spec: spec.freeze
        )
      end

      def validate_files(external_id, files)
        raise Error, "#{external_id}: files must be a non-empty array" unless files.is_a?(Array) && files.any?

        normalized = files.map.with_index do |file, index|
          raise Error, "#{external_id}: file #{index + 1} must be an object" unless file.is_a?(Hash)
          kind = file["kind"].to_s
          raise Error, "#{external_id}: unsupported file kind #{kind}" unless FILE_KINDS.include?(kind)
          digest = file["sha256"].to_s
          unless digest.match?(/\Asha256:[0-9a-f]{64}\z/)
            raise Error, "#{external_id}: file #{index + 1} needs a lowercase sha256 digest"
          end
          { "kind" => kind, "url" => validated_https(file["url"], "#{external_id} file URL"), "sha256" => digest }
        end
        unless normalized.any? { |file| file.fetch("kind") != "render" }
          raise Error, "#{external_id}: needs at least one printable file"
        end
        normalized
      end

      def validate_offers(external_id, offers)
        raise Error, "#{external_id}: offers must be a non-empty array" unless offers.is_a?(Array) && offers.any?

        offers.map do |offer|
          raise Error, "#{external_id}: offer must be an object" unless offer.is_a?(Hash)
          kind = offer["kind"].to_s
          price = Integer(offer["price_cents"].to_s, 10)
          currency = offer.fetch("currency", "USDC").to_s
          raise Error, "#{external_id}: unsupported offer kind #{kind}" unless LicenseOffer::KINDS.include?(kind)
          raise Error, "#{external_id}: offer price must be positive" unless price.positive?
          raise Error, "#{external_id}: unsupported offer currency #{currency}" unless %w[USDC HBAR].include?(currency)
          max_units = offer["max_units"]
          unless max_units.nil? || max_units.is_a?(Integer) && max_units.positive?
            raise Error, "#{external_id}: max_units must be a positive integer"
          end

          offer.slice("kind", "max_units").merge(
            "kind" => kind, "price_cents" => price, "currency" => currency, "terms_version" => "v1"
          )
        rescue ArgumentError, TypeError
          raise Error, "#{external_id}: offer price must be an integer"
        end
      end

      def compatibility(source_license)
        return [ true, "eligible after your ownership warranty" ] if ALLOWED_LICENSES.include?(source_license)
        if source_license.start_with?("cc-")
          return [ false, "Creative Commons terms remain attached; they cannot be silently replaced by a Printwright license" ]
        end
        if %w[cc0 public-domain].include?(source_license)
          return [ false, "public-domain rights cannot be made exclusive by a Printwright license" ]
        end

        [ false, "source license is missing or unsupported; establish proprietary rights before importing" ]
      end

      def build_archive(models)
        total_bytes = 0
        manifest_models = models.map.with_index do |model, model_index|
          files = model.spec.fetch("files").map.with_index do |file, file_index|
            bytes = RemoteFetcher.call(file.fetch("url"), max_bytes: Uploads::Validator.max_bytes)
            total_bytes += bytes.bytesize
            raise Error, "selected files exceed 250 MB" if total_bytes > MAX_TOTAL_FILE_BYTES
            actual = "sha256:#{Digest::SHA256.hexdigest(bytes)}"
            raise Error, "#{model.title}: downloaded #{file.fetch('kind')} hash does not match the profile" unless actual == file.fetch("sha256")

            extension = file.fetch("kind") == "render" ? render_extension(bytes) : file.fetch("kind")
            file.merge("path" => "external/#{model_index + 1}/#{file_index + 1}.#{extension}", "bytes" => bytes)
          end
          model.spec.except("files").merge(
            "files" => files.map { |file| file.slice("path", "kind") }
          ).tap { |spec| spec["_downloaded_files"] = files }
        end

        bytes = Zip::OutputStream.write_buffer do |zip|
          zip.put_next_entry("manifest.json")
          public_models = manifest_models.map { |model| model.except("_downloaded_files") }
          zip.write(JSON.generate({ version: 1, models: public_models }))
          manifest_models.each do |model|
            model.fetch("_downloaded_files").each do |file|
              zip.put_next_entry(file.fetch("path"))
              zip.write(file.fetch("bytes"))
            end
          end
        end.string
        ProfileUpload.new("external-profile.zip", bytes)
      end

      def render_extension(bytes)
        bytes.start_with?("\x89PNG".b) ? "png" : "jpg"
      end

      def validated_https(value, label)
        uri = URI.parse(value.to_s)
        unless uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.host.present? &&
            uri.userinfo.nil? && uri.fragment.nil? && value.to_s.bytesize <= 2_048
          raise Error, "#{label} must be a public HTTPS URL"
        end
        uri.to_s
      rescue URI::InvalidURIError
        raise Error, "#{label} is invalid"
      end
    end
  end
end
