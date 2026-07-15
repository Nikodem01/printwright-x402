class CreateDesigners < ActiveRecord::Migration[8.1]
  def change
    create_table :designers do |t|
      t.string :email_address, null: false
      t.string :password_digest, null: false
      t.string :display_name, null: false
      t.text :bio
      t.string :hedera_account_id
      t.boolean :verified, null: false, default: false

      t.timestamps
    end
    add_index :designers, :email_address, unique: true
  end
end
