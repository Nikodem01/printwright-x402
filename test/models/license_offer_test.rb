require "test_helper"

class LicenseOfferTest < ActiveSupport::TestCase
  setup do
    @model = Model3d.create!(designer: designers(:one), title: "Cube", slug: "cube-#{SecureRandom.hex(4)}")
  end

  test "legacy free-text offers hash their terms_md on save" do
    offer = LicenseOffer.create!(model3d: @model, kind: "personal", price_cents: 250,
      terms_version: nil, terms_md: "Print for yourself.")
    assert_equal "sha256:#{Digest::SHA256.hexdigest('Print for yourself.')}", offer.terms_hash

    offer.update!(terms_md: "Changed.")
    assert_equal "sha256:#{Digest::SHA256.hexdigest('Changed.')}", offer.terms_hash
  end

  test "changing an unsold canonical offer kind recomputes the governing terms hash" do
    offer = LicenseOffer.create!(model3d: @model, kind: "personal", price_cents: 250)

    offer.update!(kind: "commercial_unit")

    assert_equal Licensing::Documents.hash("v1", "commercial_unit"), offer.terms_hash
    assert_includes offer.terms_text, "Commercial Per-Unit Print License"
  end

  test "an offer with an active real purchase cannot mutate its commercial identity" do
    offer = LicenseOffer.create!(model3d: @model, kind: "personal", price_cents: 250)
    Purchase.create!(license_offer: offer, status: "pending", replay_key: SecureRandom.hex(32))

    assert_not offer.update(kind: "commercial_unit", price_cents: 500, max_units: 10)
    assert_includes offer.errors[:base],
      "A reserved or sold offer is immutable; create a new offer revision for future buyers."
    offer.reload
    assert_equal "personal", offer.kind
    assert_equal 250, offer.price_cents
    assert_nil offer.max_units
    assert_equal Licensing::Documents.hash("v1", "personal"), offer.terms_hash
  end

  test "failed and sandbox attempts do not freeze an otherwise unsold offer" do
    offer = LicenseOffer.create!(model3d: @model, kind: "personal", price_cents: 250)
    Purchase.create!(license_offer: offer, status: "failed_verification",
      replay_key: SecureRandom.hex(32))
    Purchase.create!(license_offer: offer, status: "delivered", sandbox: true,
      replay_key: SecureRandom.hex(32))

    assert offer.update(price_cents: 300)
  end

  test "rejects unknown kinds and non-positive prices" do
    assert_not LicenseOffer.new(model3d: @model, kind: "site_wide", price_cents: 100).valid?
    assert_not LicenseOffer.new(model3d: @model, kind: "personal", price_cents: 0).valid?
  end

  test "decimal USDC input converts exactly to the existing cents contract" do
    offer = LicenseOffer.new(model3d: @model, kind: "personal", price_usdc: "12.34")

    assert_equal 1234, offer.price_cents
    assert_equal "12.34", offer.price_usdc
    assert offer.valid?

    offer = LicenseOffer.new(model3d: @model, kind: "personal", price_usdc: "1.234")
    assert_nil offer.price_cents
    assert_not offer.valid?
    assert_equal "1.234", offer.price_usdc
  end

  test "product definitions make both rights grants explicit" do
    personal = LicenseOffer.product("personal")
    commercial = LicenseOffer.product("commercial_unit")

    assert_equal "Personal use", personal.fetch(:name)
    assert_match(/non-commercial/, personal.fetch(:summary))
    assert_equal "Commercial per-unit", commercial.fetch(:name)
    assert_match(/one physical print/, commercial.fetch(:summary))
  end

  test "remaining capacity counts real active reservations but releases failed and sandbox purchases" do
    offer = LicenseOffer.create!(model3d: @model, kind: "commercial_unit", price_cents: 100, max_units: 3)
    %w[pending delivered failed_verification].each do |status|
      Purchase.create!(license_offer: offer, status: status, replay_key: SecureRandom.hex(32), sandbox: false)
    end
    Purchase.create!(license_offer: offer, status: "failed_settlement", replay_key: SecureRandom.hex(32), sandbox: false)
    Purchase.create!(license_offer: offer, status: "delivered", replay_key: SecureRandom.hex(32), sandbox: true)

    assert_equal 2, offer.capacity_used
    assert_equal 1, offer.units_remaining
    assert_not offer.sold_out?

    Purchase.create!(license_offer: offer, status: "verified", replay_key: SecureRandom.hex(32), sandbox: false)
    assert_equal 0, offer.units_remaining
    assert offer.sold_out?
  end
end
