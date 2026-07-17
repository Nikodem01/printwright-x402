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
end
