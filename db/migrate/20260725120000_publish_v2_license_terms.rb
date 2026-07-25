class PublishV2LicenseTerms < ActiveRecord::Migration[8.1]
  # The v1 texts promised public per-model licensed-unit counts, which the
  # commitment-based certificate deliberately stops publishing. Corrected terms
  # ship as v2 rather than as an edit to v1: a published version is frozen, so
  # certificates anchored under v1 keep resolving to the exact bytes they hashed.
  #
  # Hashes are written literally because that is the point of a frozen version —
  # if app/licenses/v2/*.md ever stops hashing to these values, the documents
  # were edited after publication and the offer rows should not silently follow.
  V2_HASHES = {
    "personal" => "sha256:ff57da3b28be96dcc6270f93da768c0b5ac0c6ffe0451b1f2ba4d9a02bc32184",
    "commercial_unit" => "sha256:a99ecd158752e18eeb76b547489023f43661ee9f6c4cdc4aaa570af07de6301b"
  }.freeze

  V1_HASHES = {
    "personal" => "sha256:21e25b2a6d8d8cdc7a4c4af6c758455fbf1a218fce41e02e84db26f6538b12ef",
    "commercial_unit" => "sha256:360a410b0d94626a2d7072a257e550eaf5b374e14c63e27bb07b65987c33cda7"
  }.freeze

  def up
    change_column_default :license_offers, :terms_version, from: "v1", to: "v2"
    move_offers(from: "v1", to: "v2", hashes: V2_HASHES)
  end

  def down
    change_column_default :license_offers, :terms_version, from: "v2", to: "v1"
    move_offers(from: "v2", to: "v1", hashes: V1_HASHES)
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
