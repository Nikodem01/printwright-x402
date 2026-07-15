# Idempotent demo seeds: one demo studio, three published models with files,
# renders and license offers. Assets in db/seed_assets/ are self-authored
# placeholder solids (CC0) generated for this repo; the fuller catalog with
# externally-sourced CC-BY models (and per-model provenance) lands separately.

ASSETS = Rails.root.join("db/seed_assets")

studio = Designer.find_or_create_by!(email_address: "studio@printwright.demo") do |d|
  d.password = SecureRandom.base58(24)
  d.display_name = "Printwright Demo Studio"
  d.bio = "In-house demo studio. All models here are placeholder solids published under CC0."
  d.hedera_account_id = ENV.fetch("X402_PAY_TO", "0.0.9584959")
  d.verified = true
end

MODELS = [
  {
    slug: "beaver-with-hat",
    title: "Articulated Beaver with Hat",
    description: "A cheerful articulated beaver wearing a tiny top hat. Prints support-free; " \
                 "joints snap together off the bed. Demo placeholder geometry (pyramid solid).",
    tags: %w[beaver hat animal articulated flexi toy],
    printability: { supports: false, materials: %w[PLA PETG], est_print_minutes: 95, bed_min_mm: 40 },
    stl: "beaver-with-hat.stl", render: "beaver-with-hat.png",
    offers: [
      { kind: "personal", price_cents: 250, currency: "USDC",
        terms_md: "Personal license: print for yourself, unlimited personal copies. No resale of prints or files." },
      { kind: "commercial_unit", price_cents: 60, currency: "USDC",
        terms_md: "Commercial unit license: one licensed sale of one printed unit. Royalty per print run." }
    ]
  },
  {
    slug: "calibration-cube-20mm",
    title: "Calibration Cube 20 mm",
    description: "Classic 20 mm calibration cube for dialing in your printer. Demo placeholder geometry.",
    tags: %w[calibration cube test benchmark],
    printability: { supports: false, materials: %w[PLA ABS PETG], est_print_minutes: 25, bed_min_mm: 20 },
    stl: "calibration-cube.stl", render: "calibration-cube.png",
    offers: [
      { kind: "personal", price_cents: 120, currency: "HBAR",
        terms_md: "Personal license: print for yourself, unlimited personal copies." }
    ]
  },
  {
    slug: "hex-desk-organizer",
    title: "Hexagon Desk Organizer",
    description: "Stackable hexagonal desk organizer cell. Chain as many as your desk deserves. " \
                 "Demo placeholder geometry (hex prism).",
    tags: %w[organizer desk hexagon storage stackable],
    printability: { supports: false, materials: %w[PLA], est_print_minutes: 140, bed_min_mm: 30 },
    stl: "hex-organizer.stl", render: "hex-organizer.png",
    offers: [
      { kind: "personal", price_cents: 290, currency: "USDC",
        terms_md: "Personal license: print for yourself, unlimited personal copies." },
      { kind: "commercial_unit", price_cents: 75, currency: "USDC",
        terms_md: "Commercial unit license: one licensed sale of one printed unit." }
    ]
  }
].freeze

MODELS.each do |spec|
  stl_bytes = ASSETS.join(spec[:stl]).binread

  model = Model3d.find_or_initialize_by(slug: spec[:slug])
  model.assign_attributes(
    designer: studio,
    title: spec[:title],
    description: spec[:description],
    tags: spec[:tags],
    printability: spec[:printability],
    file_hash: "sha256:#{Digest::SHA256.hexdigest(stl_bytes)}",
    status: "published"
  )
  model.save!

  stl_file = model.model_files.find_or_create_by!(kind: "stl", position: 0)
  unless stl_file.file.attached?
    stl_file.file.attach(io: StringIO.new(stl_bytes), filename: spec[:stl], content_type: "model/stl")
  end

  render = model.model_files.find_or_create_by!(kind: "render", position: 1)
  unless render.file.attached?
    render.file.attach(io: ASSETS.join(spec[:render]).open, filename: spec[:render], content_type: "image/png")
  end

  spec[:offers].each do |offer_spec|
    offer = model.license_offers.find_or_initialize_by(kind: offer_spec[:kind])
    offer.assign_attributes(offer_spec)
    offer.save!
  end
end

puts "Seeded: #{Designer.count} designers, #{Model3d.count} models, " \
     "#{LicenseOffer.count} offers, #{ModelFile.count} files."
