require "test_helper"

class LicenseTest < ActiveSupport::TestCase
  setup do
    @offer = LicenseOffer.create!(
      model3d: Model3d.create!(designer: designers(:one), title: "Cube", slug: "cube-#{SecureRandom.hex(4)}"),
      kind: "personal", price_cents: 250
    )
  end

  def settled_purchase(offer = @offer)
    Purchase.create!(license_offer: offer, status: "settled", replay_key: SecureRandom.hex(32))
  end

  test "serials count up per offer and cert_id is the global pw-sequence" do
    first = License.allocate!(settled_purchase)
    second = License.allocate!(settled_purchase)
    assert_equal [ 1, 2 ], [ first.serial, second.serial ]
    assert_match(/\Apw-\d{6}\z/, first.cert_id)
    assert_equal first.cert_id, first.verify_slug
    assert_not_equal first.cert_id, second.cert_id
  end

  test "serials are independent between offers" do
    other = LicenseOffer.create!(model3d: @offer.model3d, kind: "commercial_unit", price_cents: 60)
    License.allocate!(settled_purchase)
    assert_equal 1, License.allocate!(settled_purchase(other)).serial
  end

  test "max_units exhaustion raises SoldOut and allocates nothing" do
    @offer.update!(max_units: 1)
    License.allocate!(settled_purchase)
    assert_raises(License::SoldOut) { License.allocate!(settled_purchase) }
    assert_equal 1, License.joins(:purchase).where(purchases: { license_offer_id: @offer.id }).count
  end

  test "anchored? follows hcs_sequence_number" do
    license = License.allocate!(settled_purchase)
    assert_not license.anchored?
    license.update!(hcs_sequence_number: 42)
    assert license.anchored?
  end
end
