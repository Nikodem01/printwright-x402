class AddAdminOperations < ActiveRecord::Migration[8.1]
  def change
    add_column :designers, :admin, :boolean, default: false, null: false
    add_index :designers, :admin

    create_table :admin_audit_logs do |t|
      t.references :actor_designer,
        foreign_key: { to_table: :designers, on_delete: :nullify }, null: true
      t.string :action, null: false
      t.string :subject_type
      t.bigint :subject_id
      t.jsonb :details, default: {}, null: false
      t.string :request_id
      t.string :ip_address
      t.datetime :created_at, null: false

      t.index %i[subject_type subject_id]
      t.index :created_at
    end
  end
end
