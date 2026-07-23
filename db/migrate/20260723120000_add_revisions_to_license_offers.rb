class AddRevisionsToLicenseOffers < ActiveRecord::Migration[8.1]
  def up
    add_column :license_offers, :revision, :integer, null: false, default: 1
    add_column :license_offers, :active, :boolean, null: false, default: true
    add_reference :license_offers, :supersedes, index: false,
      foreign_key: { to_table: :license_offers }

    execute <<~SQL
      WITH ranked AS (
        SELECT id,
               ROW_NUMBER() OVER (PARTITION BY model3d_id, kind ORDER BY id) AS revision
        FROM license_offers
      )
      UPDATE license_offers
      SET revision = ranked.revision,
          active = (ranked.revision = 1)
      FROM ranked
      WHERE license_offers.id = ranked.id
    SQL

    add_index :license_offers, [ :model3d_id, :kind ], unique: true,
      where: "active", name: "index_license_offers_on_active_model_and_kind"
    add_index :license_offers, :supersedes_id, unique: true
  end

  def down
    remove_index :license_offers, :supersedes_id
    remove_index :license_offers, name: "index_license_offers_on_active_model_and_kind"
    remove_reference :license_offers, :supersedes, foreign_key: true
    remove_column :license_offers, :active
    remove_column :license_offers, :revision
  end
end
