require "test_helper"

class LicenseOffers::ReviserTest < ActiveSupport::TestCase
  setup do
    @model = Model3d.create!(designer: designers(:one), title: "Revision",
      slug: "revision-#{SecureRandom.hex(4)}")
    @offer = @model.license_offers.create!(kind: "personal", price_cents: 100)
  end

  test "an unsold offer updates in place" do
    result = LicenseOffers::Reviser.call(model: @model,
      attributes: { id: @offer.id, kind: "personal", price_cents: 125 })

    assert_equal @offer, result
    assert_equal 125, @offer.reload.price_cents
    assert @offer.active?
    assert_equal 1, @model.all_license_offers.count
  end

  test "a reserved offer becomes an inactive historical row with one active successor" do
    purchase = Purchase.create!(license_offer: @offer, status: "pending",
      replay_key: SecureRandom.hex(32))

    revision = LicenseOffers::Reviser.call(model: @model,
      attributes: { id: @offer.id, kind: "personal", price_cents: 150 })

    assert_not @offer.reload.active?
    assert revision.active?
    assert_equal 2, revision.revision
    assert_equal @offer, revision.supersedes
    assert_equal [ revision ], @model.reload.license_offers.to_a
    assert_equal [ @offer, revision ], @model.all_license_offers.order(:revision).to_a
    assert_equal @offer, purchase.reload.license_offer
  end

  test "only one active offer per model and kind is allowed" do
    duplicate = @model.all_license_offers.build(kind: "personal", price_cents: 200)

    assert_raises ActiveRecord::RecordNotUnique do
      duplicate.save!(validate: false)
    end
  end

  test "decimal UI price updates through the cents-based revision boundary" do
    result = LicenseOffers::Reviser.call(model: @model,
      attributes: { id: @offer.id, kind: "personal", price_usdc: "3.75" })

    assert_equal @offer, result
    assert_equal 375, @offer.reload.price_cents
  end

  test "blank optional product is ignored while a priced product is created" do
    assert_nil LicenseOffers::Reviser.call(model: @model,
      attributes: { kind: "commercial_unit", price_usdc: "" })

    commercial = LicenseOffers::Reviser.call(model: @model,
      attributes: { kind: "commercial_unit", price_usdc: "5.00" })

    assert_equal "commercial_unit", commercial.kind
    assert_equal 500, commercial.price_cents
    assert_equal 2, @model.license_offers.count
  end

  test "removing a sold offer hides it from future buyers but preserves purchase history" do
    purchase = Purchase.create!(license_offer: @offer, status: "delivered",
      replay_key: SecureRandom.hex(32))

    result = LicenseOffers::Reviser.call(model: @model,
      attributes: { id: @offer.id, _destroy: "1" })

    assert_equal @offer, result
    assert_not @offer.reload.active?
    assert_empty @model.reload.license_offers
    assert_equal @offer, purchase.reload.license_offer
  end

  test "a sold offer settlement preference change creates a future revision" do
    purchase = Purchase.create!(license_offer: @offer, status: "delivered",
      replay_key: SecureRandom.hex(32))

    revision = LicenseOffers::Reviser.call(model: @model,
      attributes: { id: @offer.id, kind: "personal", price_usdc: "1.00", currency: "HBAR" })

    assert_equal "USDC", @offer.reload.currency
    assert_equal @offer, purchase.reload.license_offer
    assert_equal "HBAR", revision.currency
    assert_equal 2, revision.revision
  end
end
