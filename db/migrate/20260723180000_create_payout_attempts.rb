class CreatePayoutAttempts < ActiveRecord::Migration[8.1]
  def change
    create_table :payout_attempts do |t|
      t.references :designer, null: false, foreign_key: true
      t.references :purchase, null: false, foreign_key: true, index: { unique: true }
      t.string :ref, null: false
      t.string :asset, null: false
      t.string :status, null: false, default: "processing"
      t.integer :attempt_count, null: false, default: 0
      t.string :last_error_code
      t.string :tx_id
      t.datetime :last_attempted_at
      t.datetime :completed_at
      t.timestamps
    end

    add_index :payout_attempts, [ :designer_id, :status ]
    add_index :payout_attempts, [ :ref, :asset ]
  end
end
