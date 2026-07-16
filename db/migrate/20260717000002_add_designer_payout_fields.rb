class AddDesignerPayoutFields < ActiveRecord::Migration[8.0]
  def change
    add_column :designers, :payout_account_verified_at, :datetime
    add_column :ledger_entries, :held_by, :string, null: false, default: "treasury"
  end
end
