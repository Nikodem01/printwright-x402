require "test_helper"

class LedgerEntryTest < ActiveSupport::TestCase
  setup do
    ENV["X402_PAY_TO"] = "0.0.9584959"
    model = Model3d.create!(
      designer: designers(:one), title: "Ledger Test", slug: "ledger-test-#{SecureRandom.hex(4)}"
    )
    @offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    @purchase = Purchase.create!(
      license_offer: @offer, status: "verified",
      asset: "0.0.429274", amount_base_units: "250000",
      replay_key: SecureRandom.hex(32)
    )
  end

  test "settled transition writes a balanced 90/10 split in one transaction" do
    @purchase.transition_to!(:settled)

    entries = LedgerEntry.where(purchase: @purchase).index_by(&:entry_kind)
    assert_equal %w[designer_share platform_fee], entries.keys.sort
    assert_equal 225_000, entries["designer_share"].amount_base_units
    assert_equal 25_000, entries["platform_fee"].amount_base_units
    assert_equal 250_000, entries.values.sum(&:amount_base_units)
    assert_equal @offer.model3d.designer, entries["designer_share"].designer
    assert_equal "0.0.429274", entries["designer_share"].asset
  end

  test "odd base units floor the fee so the designer gets the remainder" do
    @purchase.update!(amount_base_units: "999")
    @purchase.transition_to!(:settled)

    entries = LedgerEntry.where(purchase: @purchase).index_by(&:entry_kind)
    assert_equal 99, entries["platform_fee"].amount_base_units
    assert_equal 900, entries["designer_share"].amount_base_units
  end

  test "record_settle! is idempotent" do
    @purchase.transition_to!(:settled)
    assert_no_difference -> { LedgerEntry.count } do
      LedgerEntry.record_settle!(@purchase)
    end
  end

  test "entries are immutable once written" do
    @purchase.transition_to!(:settled)
    entry = LedgerEntry.where(purchase: @purchase).first

    assert_raises(ActiveRecord::ReadOnlyRecord) { entry.update!(amount_base_units: 1) }
    assert_raises(ActiveRecord::ReadOnlyRecord) { entry.destroy! }
  end

  test "a settle with no recorded amount fails loudly, not silently" do
    @purchase.update!(amount_base_units: nil)
    assert_raises(TypeError) { @purchase.transition_to!(:settled) }
    assert @purchase.reload.verified?, "status change must roll back with the ledger"
  end

  test "payTo=designer marks both legs held_by designer (fee becomes a receivable)" do
    designer = @offer.model3d.designer
    designer.update!(hedera_account_id: "0.0.9604186")
    @purchase.update!(requirements_json: { "payTo" => "0.0.9604186" })
    @purchase.transition_to!(:settled)

    assert_equal %w[designer designer], LedgerEntry.where(purchase: @purchase).pluck(:held_by)
  end

  test "payTo=treasury marks both legs held_by treasury (share is owed)" do
    @purchase.update!(requirements_json: { "payTo" => ENV.fetch("X402_PAY_TO", "0.0.9584959") })
    @purchase.transition_to!(:settled)

    assert_equal %w[treasury treasury], LedgerEntry.where(purchase: @purchase).pluck(:held_by)
  end

  test "a designer claiming the treasury id still books as treasury" do
    treasury = ENV.fetch("X402_PAY_TO", "0.0.9584959")
    @offer.model3d.designer.update!(hedera_account_id: treasury)
    @purchase.update!(requirements_json: { "payTo" => treasury })
    @purchase.transition_to!(:settled)

    assert_equal %w[treasury treasury], LedgerEntry.where(purchase: @purchase).pluck(:held_by)
  end

  test "other transitions write nothing" do
    fresh = Purchase.create!(license_offer: @offer, replay_key: SecureRandom.hex(32))
    fresh.transition_to!(:verified)
    assert_empty LedgerEntry.where(purchase: fresh)
  end
end
