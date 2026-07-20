require "test_helper"

class CartsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @old_pay_to = ENV["X402_PAY_TO"]
    ENV["X402_PAY_TO"] = "0.0.9584959"
    designer = designers(:one)
    designer.update!(payout_account_verified_at: nil)
    @model = designer.models3d.create!(title: "Cart Controller", slug: "cart-controller", status: "published")
    render = @model.model_files.create!(kind: "render", position: 0)
    render.file.attach(io: Rails.root.join("db/seed_assets/gear-toy.png").open,
                       filename: "cart-controller.png", content_type: "image/png")
    @offer = @model.license_offers.create!(kind: "commercial_unit", price_cents: 60, max_units: 5)
  end

  teardown do
    @old_pay_to.nil? ? ENV.delete("X402_PAY_TO") : ENV["X402_PAY_TO"] = @old_pay_to
  end

  test "adds, edits, and removes a storefront batch line" do
    post cart_items_path, params: { model_id: @model.id, license: @offer.kind, quantity: 2 }
    assert_redirected_to cart_path

    get cart_path
    assert_select "h2", text: @model.title
    assert_select ".cart-line-thumb img", 1
    assert_select "input[name=quantity][value='2']"
    assert_select ".cart-total", text: "1.20 USDC"
    assert_select "[data-checkout-items-value]"

    patch cart_item_path(@offer), params: { quantity: 3 }
    assert_redirected_to cart_path
    get cart_path
    assert_select ".cart-total", text: "1.80 USDC"

    delete cart_item_path(@offer)
    assert_redirected_to cart_path
    get cart_path
    assert_select ".cart-empty", text: /cart is empty/i
  end

  test "rejects a quantity above remaining inventory" do
    post cart_items_path, params: { model_id: @model.id, license: @offer.kind, quantity: 6 }

    assert_redirected_to cart_path
    follow_redirect!
    assert_select ".flash-bad", text: /Only 5 units remain/
    assert_select ".cart-empty"
  end
end
