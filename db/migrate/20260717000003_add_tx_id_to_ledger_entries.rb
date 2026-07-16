class AddTxIdToLedgerEntries < ActiveRecord::Migration[8.0]
  def change
    add_column :ledger_entries, :tx_id, :string
  end
end
