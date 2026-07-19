require "test_helper"

class PurchaseTest < ActiveSupport::TestCase
  setup do
    @offer = LicenseOffer.create!(
      model3d: Model3d.create!(designer: designers(:one), title: "Cube", slug: "cube-#{SecureRandom.hex(4)}"),
      kind: "personal", price_cents: 250
    )
  end

  def purchase(status: "pending")
    Purchase.create!(
      license_offer: @offer, status: status, replay_key: SecureRandom.hex(32),
      asset: "0.0.429274", amount_base_units: "250000"
    )
  end

  test "happy path walks pending -> verified -> settled -> delivered" do
    p = purchase
    p.transition_to!(:verified)
    p.transition_to!(:settled)
    p.transition_to!(:delivered)
    assert p.reload.delivered?
  end

  test "pending can fail verification" do
    p = purchase
    p.transition_to!(:failed_verification)
    assert p.reload.failed_verification?
  end

  test "verified can fail settlement" do
    p = purchase(status: "verified")
    p.transition_to!(:failed_settlement)
    assert p.reload.failed_settlement?
  end

  test "skipping a state raises and does not persist" do
    p = purchase
    assert_raises(Purchase::InvalidTransition) { p.transition_to!(:settled) }
    assert p.reload.pending?
  end

  test "settled is the point of no return: no failure transitions out" do
    p = purchase(status: "settled")
    assert_raises(Purchase::InvalidTransition) { p.transition_to!(:failed_settlement) }
    assert_raises(Purchase::InvalidTransition) { p.transition_to!(:pending) }
  end

  test "terminal states allow nothing" do
    %w[delivered failed_verification failed_settlement].each do |terminal|
      p = purchase(status: terminal)
      Purchase::TRANSITIONS.keys.each do |target|
        assert_raises(Purchase::InvalidTransition) { p.transition_to!(target) }
      end
    end
  end

  test "replay_key is unique at the database level" do
    key = SecureRandom.hex(32)
    Purchase.create!(license_offer: @offer, replay_key: key)
    dupe = Purchase.new(license_offer: @offer, replay_key: key)
    assert_not dupe.valid?
    assert_raises(ActiveRecord::RecordNotUnique) { dupe.save!(validate: false) }
  end

  test "payment_tx_id is unique when present, multiple nulls allowed" do
    Purchase.create!(license_offer: @offer, replay_key: SecureRandom.hex(32))
    Purchase.create!(license_offer: @offer, replay_key: SecureRandom.hex(32))
    Purchase.create!(license_offer: @offer, replay_key: SecureRandom.hex(32), payment_tx_id: "0.0.7@1.2")
    dupe = Purchase.new(license_offer: @offer, replay_key: SecureRandom.hex(32), payment_tx_id: "0.0.7@1.2")
    assert_raises(ActiveRecord::RecordNotUnique) { dupe.save!(validate: false) }
  end

  test "one batch transaction may back several ordered purchases" do
    batch = PurchaseBatch.create!(replay_key: SecureRandom.hex(32))
    transaction_id = "0.0.7@9.8"
    2.times do |position|
      Purchase.create!(
        license_offer: @offer, purchase_batch: batch, batch_position: position,
        replay_key: SecureRandom.hex(32), payment_tx_id: transaction_id
      )
    end

    assert_equal 2, Purchase.where(payment_tx_id: transaction_id).count
    duplicate_position = Purchase.new(
      license_offer: @offer, purchase_batch: batch, batch_position: 1,
      replay_key: SecureRandom.hex(32), payment_tx_id: transaction_id
    )
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate_position.save!(validate: false) }
  end
end
