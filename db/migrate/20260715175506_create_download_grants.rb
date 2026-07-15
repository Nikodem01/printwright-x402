class CreateDownloadGrants < ActiveRecord::Migration[8.1]
  def change
    create_table :download_grants do |t|
      t.references :license, null: false, foreign_key: true
      t.string :token, null: false
      t.datetime :expires_at, null: false
      t.integer :uses, null: false, default: 0
      t.integer :max_uses, null: false, default: 10

      t.timestamps
    end
    add_index :download_grants, :token, unique: true
  end
end
