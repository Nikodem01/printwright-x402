class CreatePurchaseBatches < ActiveRecord::Migration[8.0]
  def change
    create_table :purchase_batches do |t|
      t.string :status, null: false, default: "pending"
      t.string :replay_key, null: false
      t.string :buyer_hint
      t.string :asset
      t.string :amount_base_units
      t.string :payment_tx_id
      t.jsonb :requirements_json, null: false, default: {}
      t.string :error_reason
      t.boolean :sandbox, null: false, default: false
      t.timestamps
    end
    add_index :purchase_batches, :replay_key, unique: true
    add_index :purchase_batches, :payment_tx_id, unique: true,
      where: "payment_tx_id IS NOT NULL"
    add_index :purchase_batches, :status

    add_reference :purchases, :purchase_batch, foreign_key: true
    add_column :purchases, :batch_position, :integer
    add_index :purchases, [ :purchase_batch_id, :batch_position ], unique: true,
      where: "purchase_batch_id IS NOT NULL"

    remove_index :purchases, :payment_tx_id
    add_index :purchases, :payment_tx_id, unique: true,
      where: "payment_tx_id IS NOT NULL AND purchase_batch_id IS NULL"
  end
end
