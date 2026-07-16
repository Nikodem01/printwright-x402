class CreateLedgerEntries < ActiveRecord::Migration[8.0]
  def change
    create_table :ledger_entries do |t|
      t.references :purchase, null: false, foreign_key: true
      t.references :designer, foreign_key: true
      t.string :entry_kind, null: false
      t.string :asset, null: false
      t.bigint :amount_base_units, null: false
      t.datetime :created_at, null: false
    end
    add_index :ledger_entries, %i[purchase_id entry_kind], unique: true
  end
end
