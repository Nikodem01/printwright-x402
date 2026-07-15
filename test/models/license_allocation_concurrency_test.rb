require "test_helper"

# Proves the offer-row lock serializes serial allocation: N threads racing on
# one offer must produce serials 1..N with no duplicates. Transactional test
# wrapping would hide the contention, so it is disabled here.
class LicenseAllocationConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  THREADS = 8

  setup do
    @designer = Designer.create!(
      email_address: "race-#{SecureRandom.hex(4)}@example.com",
      password: "password", display_name: "Race Test"
    )
    @model = Model3d.create!(designer: @designer, title: "Race", slug: "race-#{SecureRandom.hex(4)}")
    @offer = LicenseOffer.create!(model3d: @model, kind: "personal", price_cents: 250)
    @purchases = Array.new(THREADS) do
      Purchase.create!(license_offer: @offer, status: "settled", replay_key: SecureRandom.hex(32))
    end
  end

  teardown do
    # Explicit FK-order cleanup: purchases carry restrict_with_error, so a
    # cascading destroy! would abort and leak rows into the shared test DB.
    License.where(purchase: @purchases).delete_all
    Purchase.where(id: @purchases).delete_all
    @offer.delete
    @model.delete
    @designer.delete
  end

  test "concurrent allocation yields serials 1..N exactly once each" do
    barrier = Queue.new
    threads = @purchases.map do |purchase|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.pop
          License.allocate!(purchase).serial
        end
      end
    end
    THREADS.times { barrier << true }
    serials = threads.map(&:value)

    assert_equal (1..THREADS).to_a, serials.sort
  end
end
