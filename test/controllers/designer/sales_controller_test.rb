require "test_helper"

class Designer::SalesControllerTest < ActionDispatch::IntegrationTest
  setup do
    ENV["X402_PAY_TO"] = "0.0.9584959"
    @designer = designers(:one)
    @designer.update!(hedera_account_id: "0.0.9604186")
    model = Model3d.create!(designer: @designer, title: "Ledger Lamp", slug: "lamp-#{SecureRandom.hex(4)}")
    @offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    sign_in_as @designer
  end

  def settled_purchase(pay_to:, amount: "250000")
    purchase = Purchase.create!(
      license_offer: @offer, status: "verified", buyer_hint: "0.0.9067781",
      asset: "0.0.429274", amount_base_units: amount,
      payment_tx_id: "0.0.7162784@#{SecureRandom.rand(1000)}.#{SecureRandom.rand(1000)}",
      replay_key: SecureRandom.hex(32), requirements_json: { "payTo" => pay_to }
    )
    purchase.transition_to!(:settled)
    purchase
  end

  test "statement shows direct, owed, paid-out, and refunded rows with balances" do
    settled_purchase(pay_to: "0.0.9604186")                       # paid direct
    owed = settled_purchase(pay_to: "0.0.9584959")                # owed
    paid = settled_purchase(pay_to: "0.0.9584959")                # paid out
    LedgerEntry.create!(purchase: paid, designer: @designer, entry_kind: "designer_payout",
      asset: "0.0.429274", amount_base_units: "225000", held_by: "designer", tx_id: "0.0.9067781@9.9")
    refunded = settled_purchase(pay_to: "0.0.9584959")            # refunded
    LedgerEntry.create!(purchase: refunded, entry_kind: "refund",
      asset: "0.0.429274", amount_base_units: "250000", held_by: "treasury", tx_id: "0.0.9067781@8.8")

    get designer_sales_path
    assert_response :success
    assert_select "td", text: /paid direct/, count: 1
    assert_select "td", text: /\Aowed\z/, count: 1
    assert_select "td", text: /paid out/, count: 1
    assert_select "td", text: /refunded/, count: 1
    # owed balance = exactly the one owed share (225000 base units)
    assert_match "Owed to you", response.body
    assert_match "0.22 USDC", response.body
    assert_equal [ owed.id ], LedgerEntry.owed.where(designer: @designer).pluck(:purchase_id)
  end

  test "statement requires a signed-in designer and shows only their rows" do
    other = Model3d.create!(designer: designers(:two), title: "Other", slug: "other-#{SecureRandom.hex(4)}")
    other_offer = other.license_offers.create!(kind: "personal", price_cents: 100)
    p = Purchase.create!(
      license_offer: other_offer, status: "verified", asset: "0.0.429274",
      amount_base_units: "100000", replay_key: SecureRandom.hex(32),
      requirements_json: { "payTo" => "0.0.9584959" }
    )
    p.transition_to!(:settled)

    get designer_sales_path
    assert_response :success
    assert_no_match "Other", response.body

    sign_out
    get designer_sales_path
    assert_redirected_to "/login"
  end
end
