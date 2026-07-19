class CreateLibraryMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :library_memberships do |t|
      t.references :license, null: false, foreign_key: true, index: { unique: true }
      t.string :email_address, null: false

      t.timestamps
    end
    add_index :library_memberships, :email_address
  end
end
