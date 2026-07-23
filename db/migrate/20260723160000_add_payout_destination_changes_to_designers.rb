class AddPayoutDestinationChangesToDesigners < ActiveRecord::Migration[8.0]
  def change
    change_table :designers, bulk: true do |t|
      t.string :payout_pending_account_id
      t.text :payout_challenge
      t.string :payout_challenge_digest
      t.datetime :payout_challenge_expires_at
      t.datetime :payout_change_requested_at
      t.datetime :payout_proof_verified_at
      t.datetime :payout_hold_until
      t.datetime :payout_account_control_verified_at
    end
  end
end
