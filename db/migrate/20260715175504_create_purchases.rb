class CreatePurchases < ActiveRecord::Migration[8.1]
  def change
    create_table :purchases do |t|
      t.references :license_offer, null: false, foreign_key: true
      t.string :status, null: false, default: "pending"
      t.string :buyer_hint
      t.string :asset
      t.string :amount_base_units
      t.string :payment_tx_id
      t.string :replay_key, null: false
      t.jsonb :requirements_json, null: false, default: {}
      t.string :error_reason

      t.timestamps
    end
    add_index :purchases, :status
    add_index :purchases, :replay_key, unique: true
    add_index :purchases, :payment_tx_id, unique: true, where: "payment_tx_id IS NOT NULL"
  end
end
