require "digest"
require "json"
require "zip"

module CatalogImports
  class Importer
    MAX_ARCHIVE_BYTES = 250.megabytes
    MAX_EXPANDED_BYTES = 500.megabytes
    MAX_ENTRIES = 201
    MAX_MODELS = 50
    CONTENT_TYPES = {
      "stl" => "model/stl", "3mf" => "model/3mf", "step" => "model/step",
      "render" => "image/png"
    }.freeze

    EntryUpload = Struct.new(:original_filename, :bytes) do
      def size = bytes.bytesize
      def read(length = nil) = length ? io.read(length) : io.read
      def rewind = io.rewind

      private

      def io
        @io ||= StringIO.new(bytes)
      end
    end

    def self.call(designer, archive, provenance: {})
      new(designer, archive, provenance: provenance).call
    end

    def initialize(designer, archive, provenance: {})
      @designer = designer
      @archive = archive
      @provenance = provenance
    end

    def call
      bytes = archive_bytes
      entries = read_entries(bytes)
      manifest = parse_manifest(entries)
      specs = validate_manifest(manifest, entries)
      catalog_import = persist(specs, bytes)
      catalog_import.models3d.find_each { |model| AnalyzeModelMeshJob.perform_later(model.id) }
      catalog_import
    rescue Zip::Error, JSON::ParserError => error
      raise Error, "unreadable archive or manifest (#{error.class.name.demodulize})"
    rescue ActiveRecord::RecordInvalid => error
      raise Error, error.record.errors.full_messages.to_sentence
    end

    private

    def archive_bytes
      raise Error, "archive is empty" if @archive.size.to_i.zero?
      raise Error, "archive exceeds 250 MB" if @archive.size > MAX_ARCHIVE_BYTES

      @archive.rewind
      @archive.read.tap { @archive.rewind }
    end

    def read_entries(bytes)
      entries = {}
      expanded = 0
      Zip::File.open_buffer(StringIO.new(bytes)) do |zip|
        raise Error, "archive has more than #{MAX_ENTRIES} entries" if zip.entries.length > MAX_ENTRIES

        zip.each do |entry|
          next if entry.directory?
          validate_path!(entry.name)
          raise Error, "duplicate archive path #{entry.name}" if entries.key?(entry.name)
          limit = entry.name == "manifest.json" ? 1.megabyte : Uploads::Validator.max_bytes
          raise Error, "#{entry.name} expands beyond #{limit / 1.megabyte} MB" if entry.size > limit

          data = entry.get_input_stream.read
          expanded += data.bytesize
          raise Error, "archive expands beyond 500 MB" if expanded > MAX_EXPANDED_BYTES
          entries[entry.name] = data
        end
      end
      entries
    end

    def validate_path!(path)
      parts = path.split("/")
      return unless path.start_with?("/") || path.include?("\\") || parts.include?("..") || parts.include?("")

      raise Error, "unsafe archive path #{path.inspect}"
    end

    def parse_manifest(entries)
      bytes = entries["manifest.json"] || raise(Error, "manifest.json is missing")
      raise Error, "manifest.json exceeds 1 MB" if bytes.bytesize > 1.megabyte

      JSON.parse(bytes)
    end

    def validate_manifest(manifest, entries)
      raise Error, "manifest version must be 1" unless manifest.is_a?(Hash) && manifest["version"] == 1
      models = manifest["models"]
      raise Error, "manifest models must contain 1 to #{MAX_MODELS} items" unless models.is_a?(Array) && models.length.between?(1, MAX_MODELS)

      specs = models.each_with_index.map { |model, index| validate_model(model, index + 1, entries) }
      slugs = specs.map { |spec| spec.fetch(:attributes).fetch(:slug) }
      raise Error, "model slugs must be unique" unless slugs.uniq.length == slugs.length
      existing = Model3d.where(slug: slugs).pluck(:slug)
      raise Error, "slugs already exist: #{existing.join(', ')}" if existing.any?

      referenced = specs.flat_map { |spec| spec.fetch(:files).map { |file| file.fetch(:path) } }
      extras = entries.keys - referenced - [ "manifest.json" ]
      raise Error, "unreferenced archive entries: #{extras.first(5).join(', ')}" if extras.any?
      specs
    end

    def validate_model(model, number, entries)
      raise Error, "model #{number} must be an object" unless model.is_a?(Hash)
      title = model["title"].to_s.strip
      slug = model["slug"].to_s.strip
      raise Error, "model #{number} needs a title" if title.blank?
      raise Error, "model #{number} has an invalid slug" unless slug.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)

      category = model["category"].presence
      if category && !Model3d::CATEGORIES.key?(category)
        raise Error, "#{slug}: unknown category #{category}"
      end
      collections = Array(model["collections"])
      unknown = collections - Model3d::COLLECTIONS.keys
      raise Error, "#{slug}: unknown collections #{unknown.join(', ')}" if unknown.any?

      files = validate_files(slug, model["files"], entries)
      offers = validate_offers(slug, model["offers"])
      {
        attributes: {
          title: title, slug: slug, description: model["description"].to_s,
          tags: Array(model["tags"]).map(&:to_s), category: category,
          collections: collections, printability: validate_printability(slug, model["printability"])
        },
        files: files,
        offers: offers
      }
    end

    def validate_files(slug, files, entries)
      raise Error, "#{slug}: files must be a non-empty array" unless files.is_a?(Array) && files.any?

      normalized = files.map.with_index do |file, index|
        raise Error, "#{slug}: file #{index + 1} must be an object" unless file.is_a?(Hash)
        path = file["path"].to_s
        kind = file["kind"].to_s
        raise Error, "#{slug}: unsupported file kind #{kind}" unless %w[stl 3mf step render].include?(kind)
        bytes = entries[path] || raise(Error, "#{slug}: missing file #{path}")
        upload = EntryUpload.new(File.basename(path), bytes)
        reason = Uploads::Validator.reason_to_reject(upload, kind: kind)
        raise Error, "#{slug}: #{reason}" if reason

        { path: path, kind: kind, bytes: bytes }
      end
      raise Error, "#{slug}: needs at least one printable file" unless normalized.any? { |file| file.fetch(:kind) != "render" }
      normalized
    end

    def validate_offers(slug, offers)
      raise Error, "#{slug}: offers must be a non-empty array" unless offers.is_a?(Array) && offers.any?

      offers.map do |offer|
        kind = offer["kind"].to_s
        price = Integer(offer["price_cents"].to_s, 10)
        raise Error, "#{slug}: unsupported offer kind #{kind}" unless LicenseOffer::KINDS.include?(kind)
        raise Error, "#{slug}: offer price must be positive" unless price.positive?

        {
          kind: kind, price_cents: price, currency: offer.fetch("currency", "USDC"),
          max_units: offer["max_units"], terms_md: offer["terms_md"],
          terms_version: offer.fetch("terms_version", "v1")
        }
      rescue ArgumentError, TypeError
        raise Error, "#{slug}: offer price must be an integer"
      end
    end

    def validate_printability(slug, printability)
      return {} if printability.nil?
      raise Error, "#{slug}: printability must be an object" unless printability.is_a?(Hash)

      printability.slice("supports", "materials", "est_print_minutes", "bed_min_mm")
    end

    def persist(specs, archive_bytes)
      CatalogImport.transaction do
        catalog_import = @designer.catalog_imports.create!({
          manifest_digest: "sha256:#{Digest::SHA256.hexdigest(archive_bytes)}"
        }.merge(@provenance.fetch(:catalog, {})))
        models = specs.map { |spec| persist_model(catalog_import, spec) }
        snapshots = models.to_h { |model| [ model.id.to_s, Snapshot.digest(model) ] }
        catalog_import.update!(model_count: models.length, model_snapshots: snapshots, completed_at: Time.current)
        catalog_import
      end
    end

    def persist_model(catalog_import, spec)
      source = @provenance.fetch(:models, {}).fetch(spec.fetch(:attributes).fetch(:slug), {})
      model = @designer.models3d.create!(
        spec.fetch(:attributes).merge(source).merge(catalog_import: catalog_import)
      )
      spec.fetch(:offers).each { |offer| model.license_offers.create!(offer) }
      spec.fetch(:files).each_with_index do |file, position|
        record = model.model_files.create!(kind: file.fetch(:kind), position: position)
        record.file.attach(
          io: StringIO.new(file.fetch(:bytes)), filename: File.basename(file.fetch(:path)),
          content_type: content_type_for(file)
        )
      end
      model
    end

    def content_type_for(file)
      return CONTENT_TYPES.fetch(file.fetch(:kind)) unless file.fetch(:kind) == "render"

      file.fetch(:bytes).start_with?("\x89PNG".b) ? "image/png" : "image/jpeg"
    end
  end
end
