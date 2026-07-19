class CreatePrintReports < ActiveRecord::Migration[8.0]
  def change
    create_table :print_reports do |t|
      t.references :license, null: false, foreign_key: true, index: { unique: true }
      t.timestamps
    end
  end
end
