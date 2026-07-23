class AddNotificationEmailPreferencesToDesigners < ActiveRecord::Migration[8.1]
  def change
    add_column :designers, :email_on_sale, :boolean, null: false, default: true
    add_column :designers, :email_on_payout_issue, :boolean, null: false, default: true
  end
end
