class CreateChatConversations < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_conversations do |t|
      t.jsonb :turns, null: false, default: []
      t.jsonb :purchase_proposal, null: false, default: {}
      t.integer :approved_spend_cents, null: false, default: 0
      t.datetime :expires_at, null: false
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    add_index :chat_conversations, :expires_at
  end
end
