require "test_helper"

class Licensing::DocumentsTest < ActiveSupport::TestCase
  test "canonical text and hash are stable and match a stranger's recipe" do
    text = Licensing::Documents.text("v1", "personal")
    assert_includes text, "Printwright Personal Print License"
    assert_includes text, "not legal advice"

    # the documented recipe: sha256 over the exact served bytes
    assert_equal "sha256:#{Digest::SHA256.hexdigest(text)}", Licensing::Documents.hash("v1", "personal")
    assert_not_equal Licensing::Documents.hash("v1", "personal"),
                     Licensing::Documents.hash("v1", "commercial_unit")
    assert_equal "v1", Licensing::Documents.version_for_hash(
      "personal", Licensing::Documents.hash("v1", "personal")
    )
    assert_nil Licensing::Documents.version_for_hash("personal", "sha256:unknown")
  end

  test "unknown documents raise; exists? and hash lookup answer quietly; traversal is blocked" do
    assert_raises(Licensing::Documents::UnknownDocument) { Licensing::Documents.text("v9", "personal") }
    assert_not Licensing::Documents.exists?("v1", "site_wide")
    assert_not Licensing::Documents.exists?("..", "..%2Fsecrets")
    assert_nil Licensing::Documents.version_for_hash("../personal", "sha256:unknown")
    assert Licensing::Documents.exists?("v1", "commercial_unit")
  end

  test "offers on a terms_version hash the canonical document; legacy terms_md still hashes itself" do
    model = Model3d.create!(designer: designers(:one), title: "T", slug: "terms-#{SecureRandom.hex(4)}")
    offer = model.license_offers.create!(kind: "personal", price_cents: 100)
    assert_equal "v1", offer.terms_version
    assert_equal Licensing::Documents.hash("v1", "personal"), offer.terms_hash
    assert_includes offer.terms_text, "Personal Print License"

    legacy = model.license_offers.create!(kind: "commercial_unit", price_cents: 100,
      terms_version: nil, terms_md: "one-liner terms")
    assert_equal "sha256:#{Digest::SHA256.hexdigest('one-liner terms')}", legacy.terms_hash
    assert_equal "one-liner terms", legacy.terms_text
  end
end
