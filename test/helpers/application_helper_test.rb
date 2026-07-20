require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "formats offer prices and token amounts as USDC" do
    offer = Struct.new(:price_cents).new(250)

    assert_equal "2.50 USDC", offer_price(offer)
    assert_equal "2.50 USDC", format_usdc_cents(250)
    assert_equal "2.50 USDC", format_base_units(2_500_000, "0.0.429274")
  end

  test "printability_label uses the known label and humanizes unknown keys" do
    assert_equal "Supports", printability_label("supports")
    assert_equal "Minimum bed", printability_label("bed_min_mm")
    assert_equal "Estimated print time", printability_label("est_print_minutes")
    assert_equal "Materials", printability_label("materials")
    assert_equal "Layer height mm", printability_label("layer_height_mm")
  end

  test "printability_value renders supports as a plain sentence, never a raw boolean" do
    assert_equal "Not needed", printability_value("supports", false)
    assert_equal "Required", printability_value("supports", true)
  end

  test "printability_value adds a unit to the minimum bed size" do
    assert_equal "20 mm", printability_value("bed_min_mm", 20)
  end

  test "printability_value formats print time in minutes under an hour" do
    assert_equal "12 min", printability_value("est_print_minutes", 12)
  end

  test "printability_value formats print time as hours+minutes at or above an hour" do
    assert_equal "1 hr", printability_value("est_print_minutes", 60)
    assert_equal "1 hr 30 min", printability_value("est_print_minutes", 90)
    assert_equal "2 hrs 5 min", printability_value("est_print_minutes", 125)
    assert_equal "2 hrs", printability_value("est_print_minutes", 120)
  end

  test "printability_value joins materials" do
    assert_equal "PLA, PETG", printability_value("materials", %w[PLA PETG])
  end

  test "printability_value tolerates an unknown key without raising" do
    assert_equal "0.4", printability_value("layer_height_mm", "0.4")
    assert_equal "a, b", printability_value("some_future_list", %w[a b])
  end
end
