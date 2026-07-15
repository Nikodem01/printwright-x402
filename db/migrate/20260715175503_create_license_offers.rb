class CreateLicenseOffers < ActiveRecord::Migration[8.1]
  def change
    create_table :license_offers do |t|
      t.references :model3d, null: false, foreign_key: { to_table: :models3d }
      t.string :kind, null: false
      t.integer :price_cents, null: false
      t.string :currency, null: false, default: "USDC"
      t.integer :max_units
      t.text :terms_md
      t.string :terms_hash

      t.timestamps
    end
  end
end
