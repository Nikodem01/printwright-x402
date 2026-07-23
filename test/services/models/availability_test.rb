require "test_helper"

class Models::AvailabilityTest < ActiveSupport::TestCase
  setup do
    @model = designers(:one).models3d.create!(
      title: "Availability", slug: "availability-#{SecureRandom.hex(4)}", status: "published"
    )
    @model.license_offers.create!(kind: "personal", price_cents: 100)
  end

  test "pause and resume change only future-sale availability" do
    Models::Availability.call(model: @model, action: :pause)
    assert_predicate @model, :paused?

    Models::Availability.call(model: @model, action: :resume)
    assert_predicate @model, :published?
  end

  test "retirement restores to paused rather than directly to live sales" do
    Models::Availability.call(model: @model, action: :retire)
    assert_predicate @model, :retired?

    Models::Availability.call(model: @model, action: :restore)
    assert_predicate @model, :paused?
  end

  test "invalid transitions do not alter status" do
    error = assert_raises(Models::Availability::InvalidTransition) do
      Models::Availability.call(model: @model, action: :resume)
    end

    assert_match(/cannot resume a published listing/, error.message)
    assert_predicate @model.reload, :published?
  end

  test "a paused listing with no future-buyer offer cannot resume" do
    Models::Availability.call(model: @model, action: :pause)
    @model.license_offers.sole.destroy!

    error = assert_raises(Models::Availability::InvalidTransition) do
      Models::Availability.call(model: @model, action: :resume)
    end

    assert_equal "cannot resume without an active license offer", error.message
    assert_predicate @model.reload, :paused?
  end
end
