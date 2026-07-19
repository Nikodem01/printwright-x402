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
end
