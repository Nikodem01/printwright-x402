class CreateEarlyAccessSignups < ActiveRecord::Migration[8.1]
  def change
    create_table :early_access_signups do |t|
      t.string :email_address, null: false

      t.timestamps
    end
    add_index :early_access_signups, :email_address, unique: true
  end
end
