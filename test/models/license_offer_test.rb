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

  test "rejects unknown kinds and non-positive prices" do
    assert_not LicenseOffer.new(model3d: @model, kind: "site_wide", price_cents: 100).valid?
    assert_not LicenseOffer.new(model3d: @model, kind: "personal", price_cents: 0).valid?
  end

  test "remaining capacity counts real active reservations but releases failed and sandbox purchases" do
    offer = LicenseOffer.create!(model3d: @model, kind: "commercial_unit", price_cents: 100, max_units: 3)
    %w[pending delivered failed_verification].each do |status|
      Purchase.create!(license_offer: offer, status: status, replay_key: SecureRandom.hex(32), sandbox: false)
    end
    Purchase.create!(license_offer: offer, status: "refunded", replay_key: SecureRandom.hex(32), sandbox: false)
    Purchase.create!(license_offer: offer, status: "delivered", replay_key: SecureRandom.hex(32), sandbox: true)

    assert_equal 2, offer.capacity_used
    assert_equal 1, offer.units_remaining
    assert_not offer.sold_out?

    Purchase.create!(license_offer: offer, status: "verified", replay_key: SecureRandom.hex(32), sandbox: false)
    assert_equal 0, offer.units_remaining
    assert offer.sold_out?
  end
end
