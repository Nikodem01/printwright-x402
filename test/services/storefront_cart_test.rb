require "test_helper"

class StorefrontCartTest < ActiveSupport::TestCase
  setup do
    @old_pay_to = ENV["X402_PAY_TO"]
    ENV["X402_PAY_TO"] = "0.0.9584959"
    @designer = designers(:one)
    @designer.update!(payout_account_verified_at: nil)
    @personal = create_offer("Cart Personal", "personal", 100)
    @commercial = create_offer("Cart Commercial", "commercial_unit", 60, max_units: 5)
    @session = {}
    @cart = StorefrontCart.new(@session)
  end

  teardown do
    @old_pay_to.nil? ? ENV.delete("X402_PAY_TO") : ENV["X402_PAY_TO"] = @old_pay_to
  end

  test "combines different models into repeated batch API items" do
    @cart.add!(@personal, "1")
    @cart.add!(@commercial, "2")

    assert_equal 3, @cart.count
    assert_equal 220, @cart.total_cents
    assert_equal [
      { model_id: @personal.model3d_id, license: "personal" },
      { model_id: @commercial.model3d_id, license: "commercial_unit" },
      { model_id: @commercial.model3d_id, license: "commercial_unit" }
    ], @cart.payment_items
  end

  test "enforces inventory and the API batch limit" do
    error = assert_raises(StorefrontCart::Invalid) { @cart.add!(@commercial, "6") }
    assert_equal "Only 5 units remain for this offer.", error.message

    @commercial.update!(max_units: nil)
    @cart.add!(@commercial, "20")
    error = assert_raises(StorefrontCart::Invalid) { @cart.add!(@personal, "1") }
    assert_equal "A cart can contain at most 20 licenses.", error.message
  end

  test "a cart may mix offers from different designers (all settle to the treasury)" do
    other = designers(:two)
    other.update!(hedera_account_id: "0.0.9604186")
    other.update!(payout_account_verified_at: Time.current)
    direct = create_offer("Direct Paid", "personal", 80, designer: other)
    @designer.update!(hedera_account_id: "0.0.9584959")
    @designer.update!(payout_account_verified_at: Time.current)

    # Treasury-always payTo: the two offers share one payment (to the treasury)
    # and each designer is paid their share out, so the cart no longer refuses.
    @cart.add!(@personal, "1")
    @cart.add!(direct, "1")

    assert_equal 2, @cart.count
  end

  test "a cart transparently resolves a superseded offer to the current revision" do
    @cart.add!(@personal, "1")
    Purchase.create!(license_offer: @personal, status: "pending", replay_key: SecureRandom.hex(32))
    current = LicenseOffers::Reviser.call(model: @personal.model3d,
      attributes: { id: @personal.id, kind: "personal", price_cents: 175, currency: "USDC" })

    reloaded = StorefrontCart.new(@session)

    assert_equal [ current ], reloaded.entries.map(&:offer)
    assert_equal 175, reloaded.total_cents
    assert_equal({ current.id.to_s => 1 }, @session[:storefront_cart])
  end

  test "pausing a listing removes its stale cart entry and prevents re-adding it" do
    @cart.add!(@personal, "1")
    @personal.model3d.update!(status: "paused")

    reloaded = StorefrontCart.new(@session)
    assert_empty reloaded.entries
    assert_empty @session.fetch(:storefront_cart)

    error = assert_raises(StorefrontCart::Invalid) { reloaded.add!(@personal, "1") }
    assert_equal "That listing is no longer available for new purchases.", error.message
  end

  private

  def create_offer(title, kind, price_cents, max_units: nil, designer: @designer)
    model = designer.models3d.create!(title: title, slug: "#{title.parameterize}-#{SecureRandom.hex(3)}", status: "published")
    model.license_offers.create!(kind: kind, price_cents: price_cents, currency: "USDC", max_units: max_units)
  end
end
