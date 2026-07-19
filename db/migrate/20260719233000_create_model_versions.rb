class CreateModelVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :model_versions do |t|
      t.references :model3d, null: false, foreign_key: true
      t.integer :number, null: false
      t.string :file_kind, null: false
      t.string :file_hash, null: false
      t.text :changelog, null: false
      t.string :changelog_hash, null: false
      t.jsonb :event_json, null: false, default: {}
      t.string :hcs_topic_id
      t.bigint :hcs_sequence_number
      t.string :hcs_transaction_id
      t.datetime :published_at, null: false
      t.timestamps

      t.index %i[model3d_id number], unique: true
    end
  end
end
