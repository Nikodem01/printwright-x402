require "test_helper"

class PayoutAttemptTest < ActiveSupport::TestCase
  test "an attempt cannot attach one designer to another studio's purchase" do
    owner = designers(:one)
    model = owner.models3d.create!(title: "Owned payout", slug: "owned-payout-#{SecureRandom.hex(4)}")
    offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    purchase = Purchase.create!(license_offer: offer, status: "pending", replay_key: SecureRandom.hex(32))

    attempt = PayoutAttempt.new(designer: designers(:two), purchase: purchase,
      ref: "purchase-#{purchase.id}", asset: "0.0.429274")

    assert_not attempt.valid?
    assert_includes attempt.errors[:purchase], "must belong to the same designer"
  end
end
