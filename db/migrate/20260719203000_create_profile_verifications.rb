class CreateProfileVerifications < ActiveRecord::Migration[8.0]
  def change
    create_table :profile_verifications do |t|
      t.references :designer, null: false, foreign_key: true
      t.string :profile_url, null: false
      t.string :host, null: false
      t.text :challenge_token, null: false
      t.string :status, null: false, default: "pending"
      t.datetime :expires_at, null: false
      t.datetime :verified_at
      t.text :last_error
      t.timestamps
    end
    add_index :profile_verifications, [ :designer_id, :status ]

    add_column :designers, :identity_verified_at, :datetime
    add_column :designers, :verified_profile_url, :string
  end
end
