class CreateLibraryAccesses < ActiveRecord::Migration[8.1]
  def change
    # Per-email nonce for the license library cookie (S7): a leaked 30-day cookie
    # can be revoked server-side by bumping token_version.
    create_table :library_accesses do |t|
      t.citext :email_address, null: false
      t.integer :token_version, null: false, default: 1
      t.timestamps
      t.index :email_address, unique: true
    end
  end
end
