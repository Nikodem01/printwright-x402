require "zip"

module CatalogImportTestHelper
  ArchiveUpload = Struct.new(:original_filename, :bytes) do
    def size = bytes.bytesize
    def read(length = nil) = length ? io.read(length) : io.read
    def rewind = io.rewind

    private

    def io
      @io ||= StringIO.new(bytes)
    end
  end

  def catalog_archive(count: 2, missing_path: nil)
    stl = Rails.root.join("db/seed_assets/calibration-cube.stl").binread
    png = Rails.root.join("db/seed_assets/calibration-cube.png").binread
    models = count.times.map do |index|
      number = index + 1
      {
        title: "Imported model #{number}", slug: "imported-model-#{number}",
        description: "Bulk imported fixture #{number}.", tags: [ "bulk", "fixture" ],
        category: "workshop-tools", collections: [ "maker-basics" ],
        printability: { supports: false, materials: [ "PLA" ], est_print_minutes: 20 },
        files: [
          { path: "models/model-#{number}.stl", kind: "stl" },
          { path: "renders/model-#{number}.png", kind: "render" }
        ],
        offers: [ { kind: "personal", price_cents: 250, currency: "USDC" } ]
      }
    end
    manifest = { version: 1, models: models }

    bytes = Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry("manifest.json")
      zip.write(JSON.generate(manifest))
      count.times do |index|
        number = index + 1
        stl_path = "models/model-#{number}.stl"
        unless missing_path == stl_path
          zip.put_next_entry(stl_path)
          zip.write(stl)
        end
        zip.put_next_entry("renders/model-#{number}.png")
        zip.write(png)
      end
    end.string
    ArchiveUpload.new("catalog.zip", bytes)
  end

  # A bundle made only of formats the analyzer cannot read, and the same bundle
  # with a printable file added — the companion-only rule either side of its line.
  def step_only_archive = companion_archive(with_stl: false)
  def step_companion_archive = companion_archive(with_stl: true)

  def companion_archive(with_stl:)
    stl = Rails.root.join("db/seed_assets/calibration-cube.stl").binread
    step = "ISO-10303-21;\nHEADER;\nENDSEC;\nEND-ISO-10303-21;\n"
    files = [ { path: "models/part.step", kind: "step" } ]
    files.unshift({ path: "models/part.stl", kind: "stl" }) if with_stl
    manifest = {
      version: 1,
      models: [ {
        title: "Companion model", slug: "companion-model",
        description: "CAD source alongside a print file.",
        files: files,
        offers: [ { kind: "personal", price_cents: 250, currency: "USDC" } ]
      } ]
    }

    bytes = Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry("manifest.json")
      zip.write(JSON.generate(manifest))
      if with_stl
        zip.put_next_entry("models/part.stl")
        zip.write(stl)
      end
      zip.put_next_entry("models/part.step")
      zip.write(step)
    end.string
    ArchiveUpload.new("companion.zip", bytes)
  end

  # The same bytes at two paths — a buyer would be sold "two files" and receive
  # one object twice.
  def duplicate_file_archive
    stl = Rails.root.join("db/seed_assets/calibration-cube.stl").binread
    manifest = {
      version: 1,
      models: [ {
        title: "Doubled model", slug: "doubled-model",
        files: [
          { path: "models/part.stl", kind: "stl" },
          { path: "models/part-copy.stl", kind: "stl" }
        ],
        offers: [ { kind: "personal", price_cents: 250, currency: "USDC" } ]
      } ]
    }

    bytes = Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry("manifest.json")
      zip.write(JSON.generate(manifest))
      zip.put_next_entry("models/part.stl")
      zip.write(stl)
      zip.put_next_entry("models/part-copy.stl")
      zip.write(stl)
    end.string
    ArchiveUpload.new("doubled.zip", bytes)
  end

  def external_profile_document(allowed_license: "all-rights-reserved")
    stl = Rails.root.join("db/seed_assets/calibration-cube.stl").binread
    digest = "sha256:#{Digest::SHA256.hexdigest(stl)}"
    {
      schema_version: 1,
      profile: { name: "External Maker", url: "https://profiles.example/maker" },
      models: [
        {
          id: "maker-cube", title: "Maker Cube", slug: "external-maker-cube",
          description: "Original cube.", tags: [ "cube" ], category: "workshop-tools",
          collections: [ "maker-basics" ], printability: { supports: false, materials: [ "PLA" ] },
          source_url: "https://profiles.example/models/cube", source_license: allowed_license,
          files: [ { kind: "stl", url: "https://files.example/cube.stl", sha256: digest } ],
          offers: [ { kind: "personal", price_cents: 250, currency: "USDC" } ]
        },
        {
          id: "maker-remix", title: "Maker Remix", slug: "external-maker-remix",
          source_url: "https://profiles.example/models/remix", source_license: "cc-by-nc-4.0",
          files: [ { kind: "stl", url: "https://files.example/remix.stl", sha256: digest } ],
          offers: [ { kind: "personal", price_cents: 250, currency: "USDC" } ]
        }
      ]
    }
  end

  def external_profile_json(**options)
    JSON.generate(external_profile_document(**options))
  end
end
