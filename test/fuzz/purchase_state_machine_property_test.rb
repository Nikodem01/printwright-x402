require "test_helper"

class PurchaseStateMachinePropertyTest < ActiveSupport::TestCase
  SEED = 40_246
  SEQUENCES = 80
  STEPS_PER_SEQUENCE = 12
  MONEY_MOVED_STATES = %w[settled delivered refunded].freeze

  setup do
    model = Model3d.create!(
      designer: designers(:one), title: "State model", slug: "state-#{SecureRandom.hex(4)}"
    )
    @offer = model.license_offers.create!(kind: "personal", price_cents: 250)
  end

  test "every state and target pair agrees with the declared transition graph" do
    Purchase::TRANSITIONS.each_key do |starting_state|
      Purchase::TRANSITIONS.each_key do |target_state|
        purchase = build_purchase(status: starting_state)

        if Purchase::TRANSITIONS.fetch(starting_state).include?(target_state)
          purchase.transition_to!(target_state)
          assert_equal target_state, purchase.reload.status, "#{starting_state} -> #{target_state}"
        else
          assert_raises(Purchase::InvalidTransition, "#{starting_state} -> #{target_state}") do
            purchase.transition_to!(target_state)
          end
          assert_equal starting_state, purchase.reload.status, "#{starting_state} -> #{target_state} persisted"
        end
      end
    end
  end

  test "seeded transition sequences never re-enter pre-money states" do
    random = Random.new(SEED)
    states = Purchase::TRANSITIONS.keys

    SEQUENCES.times do |sequence|
      purchase = build_purchase
      oracle = "pending"
      money_moved = false

      STEPS_PER_SEQUENCE.times do |step|
        target = states.sample(random: random)
        allowed = Purchase::TRANSITIONS.fetch(oracle).include?(target)

        if allowed
          purchase.transition_to!(target)
          oracle = target
        else
          assert_raises(Purchase::InvalidTransition) { purchase.transition_to!(target) }
        end

        actual = purchase.reload.status
        assert_equal oracle, actual, "seed=#{SEED} sequence=#{sequence} step=#{step}"
        money_moved ||= MONEY_MOVED_STATES.include?(actual)
        if money_moved
          assert_includes MONEY_MOVED_STATES, actual,
            "seed=#{SEED} sequence=#{sequence} step=#{step} re-entered #{actual}"
        end
      end
    end
  end

  private

  def build_purchase(status: "pending")
    Purchase.create!(
      license_offer: @offer, status: status, replay_key: SecureRandom.hex(32),
      asset: "0.0.429274", amount_base_units: "250000", sandbox: true
    )
  end
end
