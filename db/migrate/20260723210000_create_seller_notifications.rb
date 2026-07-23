class CreateSellerNotifications < ActiveRecord::Migration[8.1]
  def change
    create_table :seller_notifications do |t|
      t.references :designer, null: false, foreign_key: true
      t.string :kind, null: false
      t.references :model3d, foreign_key: { to_table: :models3d }
      t.jsonb :payload, null: false, default: {}
      t.datetime :read_at
      t.timestamps
    end

    add_index :seller_notifications, [ :designer_id, :created_at ]
  end
end
