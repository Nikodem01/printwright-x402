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

  # A published version is a promise: certificates anchored under it hash these
  # exact bytes, and holders must be able to re-derive that hash forever. If an
  # edit ever lands in a published document, this fails before anyone's proof does.
  FROZEN_HASHES = {
    [ "v1", "personal" ] => "sha256:21e25b2a6d8d8cdc7a4c4af6c758455fbf1a218fce41e02e84db26f6538b12ef",
    [ "v1", "commercial_unit" ] => "sha256:360a410b0d94626a2d7072a257e550eaf5b374e14c63e27bb07b65987c33cda7",
    [ "v2", "personal" ] => "sha256:ff57da3b28be96dcc6270f93da768c0b5ac0c6ffe0451b1f2ba4d9a02bc32184",
    [ "v2", "commercial_unit" ] => "sha256:a99ecd158752e18eeb76b547489023f43661ee9f6c4cdc4aaa570af07de6301b"
  }.freeze

  test "published license documents are frozen at the hash their certificates anchored" do
    FROZEN_HASHES.each do |(version, kind), expected|
      assert_equal expected, Licensing::Documents.hash(version, kind),
        "#{version}/#{kind} was edited after publication — publish a new version instead"
    end
  end

  test "new offers are created on the current published version" do
    assert_equal Licensing::Documents::CURRENT_VERSION, LicenseOffer.column_defaults["terms_version"]
    assert Licensing::Documents.exists?(Licensing::Documents::CURRENT_VERSION, "personal")
  end

  test "offers on a terms_version hash the canonical document; legacy terms_md still hashes itself" do
    model = Model3d.create!(designer: designers(:one), title: "T", slug: "terms-#{SecureRandom.hex(4)}")
    offer = model.license_offers.create!(kind: "personal", price_cents: 100)
    assert_equal Licensing::Documents::CURRENT_VERSION, offer.terms_version
    assert_equal Licensing::Documents.hash(Licensing::Documents::CURRENT_VERSION, "personal"), offer.terms_hash
    assert_includes offer.terms_text, "Personal Print License"

    legacy = model.license_offers.create!(kind: "commercial_unit", price_cents: 100,
      terms_version: nil, terms_md: "one-liner terms")
    assert_equal "sha256:#{Digest::SHA256.hexdigest('one-liner terms')}", legacy.terms_hash
    assert_equal "one-liner terms", legacy.terms_text
  end
end
