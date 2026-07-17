class AddTermsVersionToLicenseOffers < ActiveRecord::Migration[8.0]
  def up
    add_column :license_offers, :terms_version, :string, default: "v1"

    # Existing offers move to the canonical v1 texts. Already-anchored
    # certificates keep the old one-liner hashes they anchored — the chain
    # copy is the contract; only new purchases reference v1.
    %w[personal commercial_unit].each do |kind|
      digest = "sha256:#{Digest::SHA256.hexdigest(File.read(Rails.root.join("app/licenses/v1/#{kind}.md")))}"
      execute <<~SQL
        UPDATE license_offers
        SET terms_version = 'v1', terms_hash = '#{digest}'
        WHERE kind = '#{kind}'
      SQL
    end
  end

  def down
    remove_column :license_offers, :terms_version
  end
end
