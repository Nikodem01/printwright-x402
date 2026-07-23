require "test_helper"

class Designers::AccountClosureTest < ActiveSupport::TestCase
  setup do
    @designer = Designer.create!(
      email_address: "closure-service@example.com", password: "password",
      display_name: "Closure Service Studio", status: :verified,
      hedera_account_id: "0.0.7007"
    )
  end

  test "retires purchase-backed models and removes only private unpurchased state" do
    catalog_import = @designer.catalog_imports.create!(
      manifest_digest: "sha256:#{'a' * 64}", model_count: 3,
      source_url: "https://example.com/private-profile",
      provenance: { "profile_name" => "Private profile" }
    )
    historical = @designer.models3d.create!(
      catalog_import: catalog_import, title: "Purchased model", slug: "closure-purchased",
      status: "published", file_hash: "sha256:#{'b' * 64}"
    )
    offer = historical.license_offers.create!(kind: "personal", price_cents: 250)
    purchase = Purchase.create!(
      license_offer: offer, status: "delivered", replay_key: SecureRandom.hex(32),
      buyer_hint: "0.0.8008", payment_tx_id: "0.0.8@1.2"
    )
    license = License.allocate!(purchase)
    draft = @designer.models3d.create!(
      catalog_import: catalog_import, title: "Private draft", slug: "closure-draft"
    )
    unsold = @designer.models3d.create!(
      catalog_import: catalog_import, title: "Unsold public", slug: "closure-unsold",
      status: "published"
    )
    profile = @designer.profile_verifications.create!(
      profile_url: "https://example.com/private-profile", host: "example.com",
      challenge_token: "secret", expires_at: 1.hour.from_now
    )
    endpoint = @designer.webhook_endpoints.create!(
      url: "https://hooks.example.com/sales", events: [ "sale.completed" ],
      secret_ciphertext: Webhooks::SecretBox.encrypt("secret")
    )
    delivery = WebhookDelivery.create!(
      webhook_endpoint: endpoint, license: license, event_key: "closure:#{license.id}",
      event_id: "evt_closure", event_type: "sale.completed", target_kind: "designer",
      url: endpoint.url, secret_ciphertext: endpoint.secret_ciphertext, payload: { "ok" => true }
    )
    payout_attempt = PayoutAttempt.create!(designer: @designer, purchase: purchase,
      ref: "purchase-#{purchase.id}", asset: "0.0.429274", status: "succeeded",
      attempt_count: 1, tx_id: "0.0.7@8.9", completed_at: Time.current)
    notification = SellerNotification.record!(designer: @designer, kind: "sale_delivered",
      model3d: historical, payload: { license_type: "personal", asset: "0.0.429274",
                                       amount_base_units: "225000", serial: 1 })

    Designers::AccountClosure.prepare!(@designer)

    assert_predicate historical.reload, :retired?
    assert_nil historical.catalog_import_id
    assert_not Model3d.exists?(draft.id)
    assert_not Model3d.exists?(unsold.id)
    assert License.exists?(license.id)
    assert Purchase.exists?(purchase.id)
    assert_not CatalogImport.exists?(catalog_import.id)
    assert_not ProfileVerification.exists?(profile.id)
    assert_not WebhookEndpoint.exists?(endpoint.id)
    assert_not WebhookDelivery.exists?(delivery.id)
    assert_not PayoutAttempt.exists?(payout_attempt.id)
    assert_not SellerNotification.exists?(notification.id)
  end

  test "refuses before mutation while designer earnings are owed" do
    model = @designer.models3d.create!(
      title: "Owed model", slug: "closure-owed", status: "published"
    )
    offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    purchase = Purchase.create!(
      license_offer: offer, status: "verified", replay_key: SecureRandom.hex(32),
      asset: "0.0.429274", amount_base_units: "250000",
      requirements_json: { "payTo" => "0.0.9584959" }
    )
    purchase.transition_to!(:settled)

    error = assert_raises(Designers::AccountClosure::Error) do
      Designers::AccountClosure.prepare!(@designer)
    end

    assert_equal :outstanding_earnings, error.code
    assert_predicate model.reload, :published?
    assert LedgerEntry.owed.where(designer: @designer).exists?
  end

  test "refuses before mutation while a real payment can still settle" do
    model = @designer.models3d.create!(
      title: "Pending model", slug: "closure-pending", status: "published"
    )
    offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    Purchase.create!(license_offer: offer, status: "verified", replay_key: SecureRandom.hex(32))

    error = assert_raises(Designers::AccountClosure::Error) do
      Designers::AccountClosure.prepare!(@designer)
    end

    assert_equal :purchase_in_progress, error.code
    assert_predicate model.reload, :published?
  end
end
