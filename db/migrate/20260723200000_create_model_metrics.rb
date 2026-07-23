class CreateModelMetrics < ActiveRecord::Migration[8.1]
  def change
    create_table :model_metrics do |t|
      t.references :model3d, null: false, foreign_key: { to_table: :models3d }
      t.date :occurred_on, null: false
      t.string :channel, null: false
      t.string :source, null: false
      t.integer :impressions, null: false, default: 0
      t.integer :views, null: false, default: 0
      t.timestamps
    end

    add_index :model_metrics, [ :model3d_id, :occurred_on, :channel, :source ],
      unique: true, name: "index_model_metrics_on_daily_dimension"
  end
end
