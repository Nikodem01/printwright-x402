class CreateLicenses < ActiveRecord::Migration[8.1]
  def change
    create_table :licenses do |t|
      t.references :purchase, null: false, foreign_key: true, index: { unique: true }
      t.integer :serial, null: false
      t.string :cert_id
      t.string :hcs_topic_id
      t.bigint :hcs_sequence_number
      t.jsonb :cert_json, null: false, default: {}
      t.string :verify_slug

      t.timestamps
    end
    add_index :licenses, :cert_id, unique: true
    add_index :licenses, :verify_slug, unique: true
  end
end
