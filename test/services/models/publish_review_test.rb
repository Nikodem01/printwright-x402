require "test_helper"

class Models::PublishReviewTest < ActiveSupport::TestCase
  setup do
    @designer = designers(:one)
    @designer.update!(hedera_account_id: "0.0.42")
    @designer.update!(payout_account_verified_at: Time.current)
    @model = @designer.models3d.create!(title: "Reviewed", slug: "reviewed-#{SecureRandom.hex(3)}")
    @file = @model.model_files.create!(kind: "stl", position: 0)
    @file.file.attach(io: StringIO.new("solid one\nendsolid one\n"),
      filename: "one.stl", content_type: "model/stl")
    @offer = @model.license_offers.create!(kind: "personal", price_cents: 100)
  end

  test "token is valid only for the exact reviewed snapshot" do
    token = Models::PublishReview.token(@model)

    assert Models::PublishReview.valid?(@model, token)
    @model.update!(title: "Changed")
    assert_not Models::PublishReview.valid?(@model, token)
  end

  test "snapshot changes with files, active offer, payout state, and publish metadata" do
    original = Models::PublishReview.digest(@model)

    @file.file.attach(io: StringIO.new("solid two\nendsolid two\n"),
      filename: "two.stl", content_type: "model/stl")
    assert_not_equal original, Models::PublishReview.digest(@model)
    file_digest = Models::PublishReview.digest(@model)

    @offer.update!(price_cents: 125)
    assert_not_equal file_digest, Models::PublishReview.digest(@model)
    offer_digest = Models::PublishReview.digest(@model)

    @designer.update!(payout_account_verified_at: nil)
    assert_not_equal offer_digest, Models::PublishReview.digest(@model)
    payout_digest = Models::PublishReview.digest(@model)

    @model.update!(category: "desk-organization")
    assert_not_equal payout_digest, Models::PublishReview.digest(@model)
  end

  test "token rejects another model, expiry, corruption, and blank input" do
    token = Models::PublishReview.token(@model)
    other = @designer.models3d.create!(title: "Other", slug: "other-#{SecureRandom.hex(3)}")

    assert_not Models::PublishReview.valid?(other, token)
    travel Models::PublishReview::EXPIRY + 1.second do
      assert_not Models::PublishReview.valid?(@model, token)
    end
    assert_not Models::PublishReview.valid?(@model, "#{token}corrupt")
    assert_not Models::PublishReview.valid?(@model, nil)
  end
end
