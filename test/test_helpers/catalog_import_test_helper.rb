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
