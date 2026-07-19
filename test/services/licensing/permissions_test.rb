require "test_helper"

class Licensing::PermissionsTest < ActiveSupport::TestCase
  test "documents make the canonical grants decidable without widening the prose" do
    personal = Licensing::Permissions.document("v1", "personal")
    commercial = Licensing::Permissions.document("v1", "commercial_unit")

    assert_equal true, personal.dig("personal_use", "allowed")
    assert_equal 0, personal.dig("commercial_units", "max_units")
    assert_equal 1, commercial.dig("commercial_units", "max_units")
    assert_equal "personal_noncommercial_only", commercial.dig("remix", "scope")
    assert_equal false, commercial.dig("resale_files", "allowed")
    assert personal.frozen?
    assert personal["personal_use"].frozen?
  end

  test "commercial decisions enforce one certificate per unit" do
    document = Licensing::Permissions.document("v1", "commercial_unit")

    assert_equal({ allowed: true, reason_code: "allowed", reason: "this certificate covers 1 commercial unit" },
      Licensing::Permissions.decide(document, "commercial_print", 1))
    denied = Licensing::Permissions.decide(document, "commercial_print", 3)
    assert_equal [ false, "commercial_unit_limit" ], denied.values_at(:allowed, :reason_code)
    assert_match "acquire one per unit", denied[:reason]
  end

  test "personal license refuses commercial printing and both kinds refuse file resale" do
    personal = Licensing::Permissions.document("v1", "personal")
    commercial = Licensing::Permissions.document("v1", "commercial_unit")

    assert_equal "commercial_use_not_granted",
      Licensing::Permissions.decide(personal, "commercial_print", 1)[:reason_code]
    assert_equal "digital_file_resale_prohibited",
      Licensing::Permissions.decide(commercial, "resell_files", 1)[:reason_code]
  end

  test "policy is available only when it matches the certificate's anchored terms hash" do
    model = Model3d.create!(designer: designers(:one), title: "P", slug: "policy-#{SecureRandom.hex(4)}")
    offer = model.license_offers.create!(kind: "personal", price_cents: 100)
    purchase = Purchase.create!(license_offer: offer, status: "settled", replay_key: SecureRandom.hex(32))
    license = License.allocate!(purchase)
    license.update!(cert_json: { "terms_hash" => offer.terms_hash })

    assert_equal "personal", Licensing::Permissions.for_license(license)[:kind]
    offer.update!(terms_version: nil, terms_md: "replacement terms for future purchases")
    assert_equal "v1", Licensing::Permissions.for_license(license)[:version]
    license.update!(cert_json: { "terms_hash" => "sha256:not-the-offer" })
    assert_nil Licensing::Permissions.for_license(license)
  end

  test "unknown and traversal documents are blocked" do
    assert_raises(Licensing::Permissions::UnknownDocument) do
      Licensing::Permissions.document("v1", "site_wide")
    end
    assert_raises(Licensing::Permissions::UnknownDocument) do
      Licensing::Permissions.document("..", "..%2Fsecret")
    end
  end
end
