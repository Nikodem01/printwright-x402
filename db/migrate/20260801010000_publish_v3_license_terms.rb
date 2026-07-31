class PublishV3LicenseTerms < ActiveRecord::Migration[8.1]
  # The v2 texts described the certificate as carrying a unit serial for every
  # license. Personal certificates no longer carry one — a sequential sale
  # number would reveal a designer's cumulative personal sales to anyone the
  # buyer shows the certificate to. Corrected terms ship as v3 rather than as
  # an edit to v2: a published version is frozen, so certificates anchored
  # under v2 keep resolving to the exact bytes they hashed.
  #
  # Hashes are written literally because that is the point of a frozen version —
  # if app/licenses/v3/*.md ever stops hashing to these values, the documents
  # were edited after publication and the offer rows should not silently follow.
  V3_HASHES = {
    "personal" => "sha256:2f767c4aa4f895af63030dabffe0a8fc299086fd773be9c7c2f3c8f1ee2de91b",
    "commercial_unit" => "sha256:28b97142e0b1f1a737b075be054429736bd8703c831cd60b3e9ceb41eafedbbd"
  }.freeze

  V2_HASHES = {
    "personal" => "sha256:ff57da3b28be96dcc6270f93da768c0b5ac0c6ffe0451b1f2ba4d9a02bc32184",
    "commercial_unit" => "sha256:a99ecd158752e18eeb76b547489023f43661ee9f6c4cdc4aaa570af07de6301b"
  }.freeze

  def up
    change_column_default :license_offers, :terms_version, from: "v2", to: "v3"
    move_offers(from: "v2", to: "v3", hashes: V3_HASHES)
  end

  def down
    change_column_default :license_offers, :terms_version, from: "v3", to: "v2"
    move_offers(from: "v3", to: "v2", hashes: V2_HASHES)
  end

  private

  # Only offers still on the old version move, and each gets the hash for its
  # own kind. Issued certificates are untouched: they carry their own
  # terms_hash, which is what verification and the permissions layer read.
  def move_offers(from:, to:, hashes:)
    hashes.each do |kind, terms_hash|
      execute(<<~SQL.squish)
        UPDATE license_offers
           SET terms_version = #{connection.quote(to)},
               terms_hash = #{connection.quote(terms_hash)},
               updated_at = NOW()
         WHERE terms_version = #{connection.quote(from)}
           AND kind = #{connection.quote(kind)}
      SQL
    end
  end
end
