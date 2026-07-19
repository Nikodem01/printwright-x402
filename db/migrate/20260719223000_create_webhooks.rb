class CreateWebhooks < ActiveRecord::Migration[8.0]
  def change
    create_table :webhook_endpoints do |t|
      t.references :designer, null: false, foreign_key: true
      t.string :url, null: false
      t.text :secret_ciphertext, null: false
      t.string :events, array: true, null: false, default: [ "sale.completed" ]
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :webhook_endpoints, [ :designer_id, :url ], unique: true

    create_table :webhook_deliveries do |t|
      t.references :webhook_endpoint, foreign_key: true
      t.references :license, null: false, foreign_key: true
      t.string :event_key, null: false
      t.string :event_id, null: false
      t.string :event_type, null: false
      t.string :target_kind, null: false
      t.string :url, null: false
      t.text :secret_ciphertext, null: false
      t.jsonb :payload, null: false, default: {}
      t.string :status, null: false, default: "pending"
      t.integer :attempts, null: false, default: 0
      t.text :last_error
      t.integer :response_code
      t.datetime :delivered_at
      t.timestamps
    end
    add_index :webhook_deliveries, :event_key, unique: true
    add_index :webhook_deliveries, [ :status, :created_at ]

    add_column :purchase_batches, :webhook_url, :string
    add_column :purchase_batches, :webhook_secret_ciphertext, :text
  end
end
